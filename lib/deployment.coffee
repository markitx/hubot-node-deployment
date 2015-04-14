AWS = require('aws-sdk')
_ = require('underscore')
util = require('util')
async = require('async')
request = require('request')
fs = require('fs')
path = require('path')
moment = require('moment')

GithubToS3 = require('./github-to-s3')
EventListener = require('./event-listener')
EventFilter = require('./event-filter')
CleanupHandler = require('./cleanup-handler')

TWENTY_FOUR_HOURS = 86400000

organizationName = process.env.HUBOT_DEPLOYMENT_GITHUB_ORGANIZATION
productionKeyName = process.env.HUBOT_DEPLOYMENT_AWS_KEY_NAME

rollbarAccessTokens = 
    'api-server'        : null, # TODO: add access token
    'public-api-server' : null, # TODO: add access token
    'webapp'            : null, # TODO: add access token
    'email-processing'  : null, # TODO: add access token
    'file-import'       : null  # TODO: add access token

roleToTemplate =
    "api-server"        : "api_server",
    "webapp"            : "webapp",
    "public-api-server" : "public_api_server",
    "worker-node"       : "worker_node",
    "hubot"             : "hubot",
    "elastic-search"    : "elastic_search",
    "marvel"            : "marvel",

appToRole =
    "api-server"        : "api-server",
    "webapp"            : "webapp",
    "public-api-server" : "public-api-server",
    "file-import"       : "worker-node",
    "email-processing"  : "worker-node",
    "hubot"             : "hubot",
    "elastic-search"    : "elastic-search",
    "elasticsearch"     : "elastic-search",
    "marvel"            : "marvel",

AWS.config.update({region: process.env.AWS_DEFAULT_REGION || 'us-east-1'})

rolesAllowedInQa =
    "webapp" : true

rolesWithoutCode =
    "elastic-search" : true,
    "marvel" : true

copyToS3 = (av, history, cb) ->
    role = appToRole[av.Name]

    if rolesWithoutCode[role]
        console.log "Role has no code, not copying anything to S3"
        return cb()
        
    githubToS3 = new GithubToS3(av.Name, av.Version)

    console.log "Copying #{av.Name}-#{av.Version} release to S3"

    githubToS3.pushReleaseToS3 false, history, cb


camelCaseAppName = (appName) ->
    (appName.split('-').map (i) ->
        i.toLowerCase().replace(/(.)/, (match, g1) ->
            g1.toUpperCase())).join('')

getVersionString = (appVersions) -> (appVersions.map (av) -> "#{av.Name}-#{av.Version.replace(/\./gi, '-')}").join('-')

getRealEnvironment = (environment) -> environment.replace('-qa', '')

isQaEnvironment = (environment) -> environment.match(/-qa/)

getAppVersion = (appName) -> camelCaseAppName(appName) + "Version"

module.exports = class Deployment
    constructor: () ->
        @ec2 = new AWS.EC2
        @cf = new AWS.CloudFormation
        @asg = new AWS.AutoScaling
        @elb = new AWS.ELB
        @dynamo = new AWS.DynamoDB
        @eventListener = new EventListener()
        @cleanupHandler = new CleanupHandler()
        @cleanupHandler.on 'cleanup', (environment, application, version) =>
            console.log "Cleaning up #{application} #{version} in #{environment}"
            appVersion =
                Name: application,
                Version: version
            filter = @events[getVersionString([appVersion])+'-'+environment]
            filter.emit 'cleanup', environment, application

        @history = {}
        @events = {}

        @_startLeaseRemovalInterval()

    deploy: (environment, appName, version, token, debug, cb) ->
        filter = new EventFilter(@eventListener)

        role = appToRole[appName]
        unless not isQaEnvironment(environment) or rolesAllowedInQa[role]
            cb("#{appName} not supported in the QA environment", null) if cb?
            return

        appVersion = { Name: appName, Version: version }

        pushStatus = @_getPushStatus [appVersion], environment, []

        console.log "Deploying #{appName}-#{version} to #{environment}"
        pushStatus "Deploy started"

        @cleanupHandler.prepareCleanup environment, appName, version

        copyToS3 appVersion, pushStatus, (err) =>
            if err?
                errorMessage = "Error copying #{role} from Github to S3: #{err}"
                console.log errorMessage
                pushStatus errorMessage
                cb(new Error(errorMessage)) if cb?
                return
            unless @_checkCancel([appVersion], environment)
                @_deploy(filter, environment, [appVersion], role, token, debug, cb)

        @events[getVersionString([appVersion])+'-'+environment] = filter
        return filter

    getVersion: (environment, appName, cb) ->
        role = appToRole[appName]
        @_getVpcAndLoadBalancer environment, (err, vpc, lb) =>
            if err?
                console.log "Unable to find VPC and load balancer stacks: #{err}"
                cb(err, null) if cb?
                return

            vpcOutput = _.find vpc.Outputs, (o) -> o.OutputKey == 'VpcId'
            vpcId = vpcOutput.OutputValue
            @_getRoleStacks environment, role, vpcId, (err, roleStacks) =>
                if err?
                    console.log "Unable to get role stacks for #{appName}"
                    cb(err, null) if cb?
                    return

                currentStack = roleStacks[0]
                unless currentStack?
                    message = "Could not find running instance of #{appName} in #{environment}";
                    console.log message
                    cb(message, null) if cb?
                    return

                versionParameterKey = getAppVersion(appName)
                version = _.find(currentStack.Parameters, (p) -> p.ParameterKey == versionParameterKey)
                cleanedUp = roleStacks.length <= 1
                uncleanedVersions = roleStacks[1..].map((stack) -> 
                    oldVersion = _.find(stack.Parameters, (p) -> p.ParameterKey == versionParameterKey)
                    if oldVersion?
                        oldVersion.ParameterValue
                    else
                        'unknown'
                )
                result =
                    version: version.ParameterValue
                    cleanedUp: cleanedUp
                    uncleanedVersions: uncleanedVersions

                cb(null, result)

    cleanUp: (environment, appName, cb) ->
        role = appToRole[appName]
        @_deleteOldVersions environment, role, cb

    rollback: (environment, appName, cb) ->
        role = appToRole[appName]
        @_getVpcAndLoadBalancer environment, (err, vpc, lb) =>
            if err?
                console.log "Unable to find VPC stack: #{err}"
                cb(err, null) if cb?
                return
            unless vpc?
                console.log "Unable to find VPC stack"
                cb('Unable to find VPC stack', null) if cb?
                return

            vpcOutput = _.find vpc.Outputs, (o) -> o.OutputKey == 'VpcId'
            vpcId = vpcOutput.OutputValue

            @_enableOldVersion environment, role, vpcId, false, cb

    deployMultiple: (environment, appVersions, token, deploy, cb) ->
        filter = new EventFilter(@eventListener)

        roles = _.groupBy(appVersions, (av) -> appToRole[av.Name])

        unless not isQaEnvironment(environment) or (_.keys(roles).every (r) -> rolesAllowedInQa[r])
            cb("#{util.inspect(_.pluck(appVersions, 'Name'))} not all supported in QA environment", null)
            return

        appVersions.forEach (av) =>
            @cleanupHandler.prepareCleanup environment, av.Name, av.Version
            console.log "Deploying #{av.Name}-#{av.Version} to #{environment}"

        _.pairs(roles).forEach (kvp) =>
            role = kvp[0]
            versions = kvp[1]

            console.log "Deploying role: #{role} and versions: #{util.inspect(versions)}"

            async.series (versions.map (av) -> (cb) -> copyToS3(av, cb)), (err, results) =>
                if err?
                    errorMessage = "Error copying #{role} from Github to S3: #{err}"
                    console.log errorMessage
                    cb(new Error(errorMessage)) if cb?
                    return
                @_deploy(filter, environment, versions, role, token, debug, cb)

        return filter

    cancelDeploy: (appVersion, environment, cb) ->
        history = @getHistory appVersion, environment
        unless _.find(history, (status) -> status.status == 'Stack creation in process')?
            cb()
            return false
        role = appToRole[appVersion.Name]
        versionString = getVersionString [appVersion]
        tags = [
            { Key: "Environment", Value: environment }
            { Key: "Role", Value: role }
            { Key: "Name", Value: "#{role}-#{versionString}" }
        ]
        @_getVpcAndLoadBalancer environment, (err, vpc, lb) =>
            if err?
                console.log "Unable to find VPC stack: #{err}"
                cb(err, null) if cb?
                return
            unless vpc?
                console.log "Unable to find VPC stack"
                cb('Unable to find VPC stack', null) if cb?
                return

            vpcOutput = _.find vpc.Outputs, (o) -> o.OutputKey == 'VpcId'
            vpcId = vpcOutput.OutputValue

            parem = {
                StackName: "#{role}-#{versionString}-#{environment}-#{vpcId}",
                Tags: tags }

            @_deleteStack role, parem, cb
        return true

    destroyDeploy: (environment, application, version, cb) ->
        @_getVpcAndLoadBalancer environment, (err, vpc, lb) =>
            if err?
                console.log "Unable to find VPC stack: #{err}"
                cb(err, null) if cb?
                return
            unless vpc?
                console.log "Unable to find VPC stack"
                cb('Unable to find VPC stack', null) if cb?
                return

            vpcOutput = _.find vpc.Outputs, (o) -> o.OutputKey == 'VpcId'
            vpcId = vpcOutput.OutputValue

            role = appToRole[application]

            @_getRoleStacks environment, role, vpcId, (err, roleStacks) =>
                appVersion =
                    Name: application,
                    Version: version

                versionString = getVersionString [appVersion]

                stackName = "#{role}-#{versionString}-#{environment}-#{vpcId}"

                roleStacks = roleStacks.filter (stack) -> stack.StackName == stackName

                if roleStacks.length != 1
                    return cb(new Error("Unable to find #{application} #{version} in #{environment}, can't destroy"))

                stack = roleStacks[0]

                if !stack.StackStatus.match(/rollback/i)
                    return cb(new Error("Deploy did not fail, can't destroy"))

                @_deleteStack role, stack, cb

        return true

    getHistory: (appVersion, environment) ->
        return @history[getVersionString([appVersion])+'-'+environment]

    getEvents: (appVersion, environment) ->
        return @events[getVersionString([appVersion])+'-'+environment]

    preserve: (environment, appName, cb) ->
        @cleanupHandler.cancelCleanup environment, appName
        cb()

    addDevIp: (ipAddress, persist, user, cb) ->
        @_getVpcAndLoadBalancer 'development', (err, vpc, lb) =>

            key = lb.Outputs.filter (item) -> item.OutputKey == 'ElasticSearchLoadBalancerSecurityGroup' || item.OutputKey == 'MarvelLoadBalancerSecurityGroup'

            @_authorizeIpAddress ipAddress, key[0].OutputValue, (err, data) =>
                return cb(err) if err?

                @_authorizeIpAddress ipAddress, key[1].OutputValue, (err, data) =>
                    return cb(err) if err?
                    @_recordLease ipAddress, user, persist, cb

    removeDevIp: (ipAddress, cb) ->
        @_getVpcAndLoadBalancer 'development', (err, vpc, lb) =>

            key = lb.Outputs.filter (item) -> item.OutputKey == 'ElasticSearchLoadBalancerSecurityGroup' || item.OutputKey == 'MarvelLoadBalancerSecurityGroup'

            @_deauthorizeIpAddress ipAddress, key[0].OutputValue, (err, data) =>
                return cb(err) if err?
                
                @_deauthorizeIpAddress ipAddress, key[1].OutputValue, (err) =>
                    return cb(err) if err?

                    params = {
                        Key: { 
                            ipAddress: {
                                S: ipAddress
                            }
                        },
                        TableName: 'development-ip-leases'
                    }
                    @dynamo.deleteItem params, cb

    _startLeaseRemovalInterval: () ->
        setInterval (() => 
            @_removeExpiredLeases (err, expired) ->
                if err?
                    console.log "ERROR: Failed to expire leases"
                    console.log err
                    return
                console.log "Expired dev ip #{lease.ipAddress} for #{lease.user}" for lease in expired
                if expired.length > 0
                    console.log "Finished expiring leases"
        ), 5 * 60 * 1000 # Every 5 minutes

    _recordLease: (ipAddress, user, persist, cb) ->
        date = new Date

        params = {
            Item: { 
                timestamp: { 
                    N: date.valueOf().toString()
                },
                user: {
                    S: user
                },
                persist: {
                    BOOL: persist
                },
                ipAddress: {
                    S: ipAddress
                }
            },
            TableName: 'development-ip-leases'
        }

        @dynamo.putItem params, cb

    _removeExpiredLeases: (cb) ->
        now = new Date
        expirationTime = now.valueOf() - TWENTY_FOUR_HOURS
        params = {
            TableName: 'development-ip-leases',
            ScanFilter: {
                timestamp: {
                    ComparisonOperator: 'LT',
                    AttributeValueList: [
                        {
                            N: expirationTime.toString()
                        }
                    ]
                },
                persist: {
                    ComparisonOperator: 'NE',
                    AttributeValueList: [
                        {
                            BOOL: true
                        }
                    ]
                }
            }
        }
        @dynamo.scan params, (err, data) =>
            if err?
                console.log "ERROR: Failed to find leases"
                console.log err
                return cb(err)

            expiring = data.Items.map (item) -> { timestamp: item.timestamp.N, ipAddress: item.ipAddress.S, persist: item.persist.BOOL, user: item.user.S }
            async.each(expiring,
                (item, done) =>
                    @removeDevIp item.ipAddress, done
                (err) ->
                    cb(err, expiring)
            )

    _deauthorizeIpAddress: (ipAddress, securityGroupId, cb) ->
        params = {
            DryRun: false,
            GroupId: securityGroupId,
            IpPermissions: [
                {
                    FromPort: 443,
                    IpProtocol: 'tcp',
                    IpRanges: [
                        {
                        CidrIp: "#{ipAddress}/32"
                        },
                    ],
                    ToPort: 443
                }
            ]
        }
        @ec2.revokeSecurityGroupIngress params, (err, data) ->
            if err 
                console.log(err, err.stack) # an error occurred
            cb(err, data) 

    _authorizeIpAddress: (ipAddress, securityGroupId, cb) ->
        params = {
            DryRun: false,
            GroupId: securityGroupId,
            IpPermissions: [
                {
                    FromPort: 443,
                    IpProtocol: 'tcp',
                    IpRanges: [
                        {
                        CidrIp: "#{ipAddress}/32"
                        },
                    ],
                    ToPort: 443
                }
            ]
        }
        @ec2.authorizeSecurityGroupIngress params, (err, data) ->
            if err 
                console.log(err, err.stack) # an error occurred
            cb(err, data)            


    _disableOldVersions: (environment, role, vpcId, cb) ->
        @_getRoleStacks environment, role, vpcId, (err, roleStacks) =>
            return cb(err, null) if err? and cb?

            newStack = roleStacks[0]

            @_waitForInService role, newStack, (err, data) =>
                if err?
                    cb(err, null) 
                    return

                oldStacks = roleStacks[1..]

                if oldStacks.length == 0
                    console.log "No old versions to disable"
                    cb(null, null) if cb?
                    return

                oldVersions = (oldStacks.map (s) -> _.find(s.Tags, (t) -> t.Key == 'Name').Value).join(',')

                async.waterfall [
                    ((cb) => async.parallel (oldStacks.map (s) => (cb) => @_disableStack(s, cb)), (err, results) =>
                        if err?
                            console.log "Error disabling old stacks for #{oldVersions}: #{err}"
                        else
                            console.log "Finished disabling old stacks for #{oldVersions}"
                        cb() if cb?
                    ),
                    ((cb) => async.parallel (oldStacks.map (s) => (cb) => @_stopInstances(role, s, cb)), (err, results) =>
                        if err?
                            console.log "Error stopping instances for #{oldVersions}: #{err}"
                        else
                            console.log "Finished stopping instances for #{oldVersions}"
                        cb(err, results) if cb?
                    )
                ], (err, results) ->
                    if err?
                        console.log "Error disabling old versions #{err}"
                    else
                        console.log "Done disabling old versions for #{oldVersions}"
                    cb(err, results)

    _deleteOldVersions: (environment, role, cb) ->
        @_getVpcAndLoadBalancer environment, (err, vpc, lb) =>
            if err?
                console.log "Unable to find VPC stack: #{err}"
                cb(err, null) if cb?
                return
            unless vpc?
                console.log "Unable to find VPC stack"
                cb('Unable to find VPC stack', null) if cb?
                return

            vpcOutput = _.find vpc.Outputs, (o) -> o.OutputKey == 'VpcId'
            vpcId = vpcOutput.OutputValue

            @_getRoleStacks environment, role, vpcId, (err, roleStacks) =>
                currentStack = roleStacks[0];
                unless /^(CREATE_COMPLETE|UPDATE_COMPLETE)$/g.test(currentStack.StackStatus)
                    console.log("Current deploy not finished");
                    cb("Current deploy not finished", []) if cb?;
                    return;

                @_areInstancesInService role, currentStack, (err,inService) =>
                    if err
                        console.log "Error checking to see if instances in service"
                        console.log err
                        cb(err, null) if cb?
                        return

                    unless inService
                        console.log "New instances not in service"
                        cb("New instances not in service", null) if cb?
                        return

                    oldStacks = roleStacks[1..]

                    oldVersions = (oldStacks.map (s) -> _.find(s.Tags, (t) -> t.Key == 'Name').Value).join(',')

                    console.log "Starting delete of #{oldVersions}"
                    async.parallel (oldStacks.map (s) => (cb) => @_deleteStack(role, s, cb)), (err, results) =>
                        console.log "Finished starting delete of #{oldVersions}"
                        cb(null, oldStacks) if cb?

    _enableOldVersion: (environment, role, vpcId, debug, cb) ->
        @_getRoleStacks environment, role, vpcId, (err, roleStacks) =>
            console.log "Error getting stacks #{err}" if err? and cb?
            return cb(err, null) if err? and cb?

            lastVersionStack = roleStacks[1]
            unless lastVersionStack?
                errorMessage = "No last version to rollback to for #{role} in #{vpcId}"
                console.log(errorMessage)
                cb(errorMessage, null) if cb?
                return

            console.log "Enabling stack #{_.find(lastVersionStack.Tags, (t) -> t.Key == 'Name').Value} for #{role}"

            currentStack = roleStacks[0]

            @_enableStack lastVersionStack, (err, data) =>
                if err?
                    errorMessage = "Error enabling #{lastVersionStack.StackName} for #{role} in #{vpcId}"
                    console.log errorMessage
                    console.log err
                    cb(errorMessage,  null) if cb?
                    return

                console.log "Starting instances for stack #{_.find(lastVersionStack.Tags, (t) -> t.Key == 'Name').Value} for #{role}"
                @_startInstances role, lastVersionStack, (err, data) =>
                    if err?
                        errorMessage = "Error starting instances in #{lastVersionStack.StackName} for #{role} in #{vpcId}"
                        console.log errorMessage
                        console.log err
                        cb(errorMessage,  null) if cb?
                        return

                    @_waitForInService role, lastVersionStack, (err, data) =>
                        return cb(err, null) if err?
                        unless debug?
                            console.log "Deleting stack #{_.find(currentStack.Tags, (t) -> t.Key == 'Name').Value} for #{role}"
                            @_deleteStack role, currentStack, cb

    _areInstancesInService: (role, stack, cb) ->
        loadBalancer = _.find(stack.Parameters, (p) -> p.ParameterKey == camelCaseAppName(role) + 'LoadBalancer')

        autoScalingGroupName = _.find(stack.Outputs,  (o) -> o.OutputKey == 'AutoScalingGroup').OutputValue
        @asg.describeAutoScalingGroups { AutoScalingGroupNames: [autoScalingGroupName] }, (err, data) =>
            if err?
                console.log("Error getting autoscaling instances #{err}")
                cb(err, null) if cb?
                return

            autoScalingGroup = data.AutoScalingGroups[0]

            instances = autoScalingGroup.Instances.map (i) -> _.pick(i, 'InstanceId')

            if instances.length == 0
                return cb(null, false) 

            if loadBalancer
                @elb.describeInstanceHealth { LoadBalancerName: loadBalancer.ParameterValue, Instances: instances }, (err, data) =>
                    return cb(err, null) if err? or !data?
                    # It is possible describeInstanceHealth has returned ALL attached instances instead of just the instances
                    # we care about.  We need to filter the returned instances for the instances of this version
                    # to make sure we only return they are healthy if they are actually attached to the ELB.
                    # The case where this can happen is:
                    #   1. Deploy a bad version that doesn't start and will never be marked as healthy in the ELB
                    #   2. Rollback after the instance is created but before we timeout waiting for instances to get healthy
                    #   3. This causes the bad version's instance to be deleted which leaves only the good instance
                    #   4. In this case we should not report the instances as being in service.
                    versionInstances = data.InstanceStates.filter (i) -> instances.some (ii) -> ii.InstanceId == i.InstanceId
                    if versionInstances.length == 0
                        return cb(err, false)
                    inService = versionInstances.every (s) -> s.State == 'InService'
                    cb(err, inService)
            else
                inService = autoScalingGroup.Instances.every (i) -> i.LifecycleState == 'InService'
                cb(null, inService)

    _waitForInService: (role, stack, cb) ->
        inService = false
        count = 0
        async.doUntil(
            (callback) => @_areInstancesInService(role, stack, (err, allInService) =>
                inService = allInService
                count++
                return callback() if inService
                # If all instances are not in service wait
                # 30 seconds and try again
                setTimeout(callback, 30000)
            ),
            () -> (inService or count >= 20),
            (err) ->
                return cb(null, 'in-service') if inService
                cb("Instances for #{util.inspect(stack)} did not get healthy in 5 minutes", null)
        )


    _deleteStack: (role, stack, cb) ->
        @cf.deleteStack { StackName: stack.StackName }, (err, data) ->
            if err?
                errorMessage = "Error deleting stack #{stack.StackName} for #{role}"
                console.log errorMessage
                cb(errorMessage, null) if cb?
                return

            console.log "Started delete of stack #{_.find(stack.Tags, (t) -> t.Key == 'Name').Value} for #{role}"

            return cb(null, data) if cb?

    _getRoleStacks: (environment, role, vpcId, cb) ->
        @cf.describeStacks (err, data) =>
            if err?
                console.log("Error finding stacks for #{role}: #{err}")
                cb(err, null) if cb?
                return

            stacks = data.Stacks
            roleStacks = stacks.filter (s) =>
                (s.Tags.some (t) => t.Key == 'Role' && t.Value == role) and
                (s.Tags.some (t) => t.Key == 'Environment' && t.Value == environment) and
                (s.Parameters.some (p) => p.ParameterKey == 'VpcId' && p.ParameterValue == vpcId)

            roleStacks.sort (s1, s2) -> s2.CreationTime - s1.CreationTime

            cb(null, roleStacks) if cb?

    _disableStack: (stack, cb) ->
        autoScalingGroup = _.find(stack.Outputs, (o) -> o.OutputKey == 'AutoScalingGroup')
        @asg.suspendProcesses { AutoScalingGroupName: autoScalingGroup.OutputValue, ScalingProcesses: ['Launch', 'AddToLoadBalancer'] }, (err, data) ->
            cb(err, data) if cb?

    _enableStack: (stack, cb) ->
        autoScalingGroup = _.find(stack.Outputs, (o) -> o.OutputKey == 'AutoScalingGroup')
        @asg.resumeProcesses { AutoScalingGroupName: autoScalingGroup.OutputValue, ScalingProcesses: ['Launch', 'AddToLoadBalancer'] }, (err, data) ->
            cb(err, data) if cb?

    _startInstances: (role, stack, cb) ->
        loadBalancer = _.find(stack.Parameters, (p) -> p.ParameterKey == camelCaseAppName(role) + 'LoadBalancer')
        autoScalingGroupName = _.find(stack.Outputs,  (o) -> o.OutputKey == 'AutoScalingGroup').OutputValue
        @asg.describeAutoScalingGroups { AutoScalingGroupNames: [autoScalingGroupName] }, (err, data) =>
            if err?
                console.log("Error getting autoscaling instances #{err}")
                cb(err, null) if cb?
                return
            autoScalingGroup = data.AutoScalingGroups[0]
            asgInstances = autoScalingGroup.Instances.filter (i) -> i.LifecycleState == 'InService'
            instances = autoScalingGroup.Instances.map (i) -> { InstanceId: i.InstanceId }
            if loadBalancer and asgInstances.length > 0
                @elb.registerInstancesWithLoadBalancer { LoadBalancerName: loadBalancer.ParameterValue, Instances: instances }, (err, data) =>
                    cb(err, data) if cb?
            else
                @_waitForInService role, stack, cb

    _stopInstances: (role, stack, cb) ->
        loadBalancer = _.find(stack.Parameters, (p) -> p.ParameterKey == camelCaseAppName(role) + 'LoadBalancer')
        autoScalingGroupName = _.find(stack.Outputs,  (o) -> o.OutputKey == 'AutoScalingGroup').OutputValue
        @asg.describeAutoScalingGroups { AutoScalingGroupNames: [autoScalingGroupName] }, (err, data) =>
            if err?
                console.log("Error getting autoscaling instances #{err}")
                cb(err, null) if cb?
                return
            if data.AutoScalingGroups.length == 0
                cb(null, null) if cb?
                return

            autoScalingGroup = data.AutoScalingGroups[0]
            terminateInstances = autoScalingGroup.Tags.some (tag) -> tag.Key == "TerminateInstancesOnNewVersion" and tag.Value == "true"
            if autoScalingGroup.Instances.length == 0
                cb(null, null) if cb?
                return

            if loadBalancer and not terminateInstances
                @elb.deregisterInstancesFromLoadBalancer { LoadBalancerName: loadBalancer.ParameterValue, Instances: autoScalingGroup.Instances.map (i) -> { InstanceId: i.InstanceId } }, (err, data) =>
                    cb(err, data) if cb?
            else
                @ec2.stopInstances { InstanceIds: _.pluck(autoScalingGroup.Instances, 'InstanceId') }, (err, data) =>
                    cb(err, data) if cb?

    _useQaParams: (lbOutputs) ->
        qaParameters = lbOutputs.filter (p) -> p.ParameterKey.match(/qa/i)
        nonQaParameters = lbOutputs.filter (p) -> !p.ParameterKey.match(/qa/i)

        nonQaParameters = nonQaParameters.map (p) -> [p.ParameterKey, p.ParameterValue]
        qaParameters = qaParameters.map (p) -> [p.ParameterKey.replace(/qa/gi, ''), p.ParameterValue]

        paramObject = _.object(nonQaParameters.concat(qaParameters))

        return _.pairs(paramObject).map (kvp) -> { ParameterKey: kvp[0], ParameterValue: kvp[1] }

    _readValidTemplate: (template, cb) ->
        templatePath = path.resolve(__dirname, "../templates/#{template}.template")
        fs.readFile templatePath, (err, data) =>
            return cb(err) if err?
            templateBody = data.toString()
            @cf.validateTemplate TemplateBody: templateBody, (err, data) ->
                cb(err, data, templateBody)

    _getPushStatus: (appVersions, environment, setValue) ->
        appStrings = appVersions.map (av) -> getVersionString([av])+'-'+environment
        return (status) =>
            appStrings.forEach (name) =>
                unless @history[name]?
                    @history[name] = []
                @history[name] = setValue if setValue?
                message =
                    'status': status,
                    'time': moment()
                @history[name].push(message)

    _deploy: (filter, environment, appVersions, role, token, debug, cb) ->
        pushStatus = @_getPushStatus appVersions, environment
        template = roleToTemplate[role]
        return if @_checkCancel(appVersions, environment)
        pushStatus("Getting Vpc and LoadBalancer")
        @_getVpcAndLoadBalancer environment, (err, vpc, lb) =>
            if err?
                console.log "Unable to find VPC and load balancer stacks: #{err}"
                cb(err, null) if cb?
                return
            unless vpc?
                console.log "Unable to find VPC stack"
                cb('Unable to find VPC stack', null) if cb?
                return
            unless lb?
                console.log "Unable to find load balancer stack"
                cb('Unable to find load balancer stack stack', null) if cb?
                return

            vpcOutput = _.find vpc.Outputs, (o) -> o.OutputKey == 'VpcId'
            vpcId = vpcOutput.OutputValue

            vpcOutputs = @_outputsToParameters vpc.Outputs
            lbOutputs = @_outputsToParameters lb.Outputs

            versionString = getVersionString(appVersions)
            return if @_checkCancel(appVersions, environment)
            pushStatus("Getting RoleStacks")
            @_getRoleStacks environment, role, vpcId, (err, roleStacks) =>
                oldVersion = roleStacks[0]

                versionParameters = appVersions.map (av)-> { ParameterKey: getAppVersion(av.Name), ParameterValue: av.Version }

                if oldVersion?
                    oldVersionParameters = oldVersion.Parameters.filter (p) -> p.ParameterKey.match(/Version/i)
                    currentVersions = _.pluck(versionParameters, 'ParameterKey')
                    otherOldVersions = oldVersionParameters.filter (p) -> !_.contains(currentVersions, p.ParameterKey)
                    versionParameters = versionParameters.concat(otherOldVersions)

                console.log "Creating stack for #{role}-#{versionString}"

                realEnvironment = getRealEnvironment(environment)

                if realEnvironment != environment
                    lbOutputs = @_useQaParams(lbOutputs)

                params = lbOutputs.concat(vpcOutputs).concat(versionParameters).concat ([
                        { ParameterKey: 'KeyName', ParameterValue: productionKeyName },
                        { ParameterKey: 'Environment', ParameterValue: realEnvironment } ])
                return if @_checkCancel(appVersions, environment)
                pushStatus("Validating Template")
                @_readValidTemplate template, (err, data, templateBody) =>
                    if err?
                        console.log "Error reading valid template #{err}"
                        cb(err, null) if cb?
                        return

                    allowedParams = _.pluck(data.Parameters, 'ParameterKey')

                    params = params.filter (p) -> allowedParams.some (pk) -> p.ParameterKey == pk

                    tags = [
                        { Key: "Environment", Value: environment }
                        { Key: "Role", Value: role }
                        { Key: "Name", Value: "#{role}-#{versionString}" }
                    ]

                    parem = {
                        StackName: "#{role}-#{versionString}-#{environment}-#{vpcId}",
                        TemplateBody: templateBody,
                        Parameters: params,
                        DisableRollback: debug,
                        NotificationARNs: [@eventListener.getSnsArn()],
                        Capabilities: ['CAPABILITY_IAM'],
                        Tags: tags }

                    return if @_checkCancel(appVersions, environment)

                    pushStatus("Creating Stack")
                    @cf.createStack parem, (err, data) =>
                            if err?
                                errorMessage = "Error creating stack: #{err}"
                                console.log errorMessage
                                cb(errorMessage, null)
                                return
                            console.log "Creating stack #{util.inspect(data)}"

                            filter.addStack(data.StackId, appVersions)

                            filter.on 'complete', (stackId, applications) =>
                                @_recordDeploy appVersions, environment, token

                                appVersions.forEach (appVersion) =>
                                    @cleanupHandler.queueCleanup environment, appVersion.Name, appVersion.Version

                                @_disableOldVersions environment, role, vpcId, (err, data) ->
                                    if err?
                                        pushStatus "Unable to disable old version, new version never healthy"
                                        filter.emit 'error'
                                        return
                                    filter.emit 'live-in-elb'
                                    pushStatus "Disabled old versions after deployment"

                            filter.on 'error', (stackId, applications) =>
                                console.log "Encountered error while creating stack"
                                pushStatus("Encountered error while creating stack")
                                @_enableOldVersion environment, role, vpcId, () =>
                                    unless debug?
                                        @_deleteStack role, parem, (err, data) ->

                            pushStatus("Stack creation in process")
                            cb(err, appVersions) if cb?
                            

    _outputsToParameters: (outputs) ->
        outputs.map (o) -> { ParameterKey: o.OutputKey, ParameterValue: o.OutputValue }

    _getVpcAndLoadBalancer: (environment, cb) ->
        environment = getRealEnvironment(environment)

        @cf.describeStacks (err, data) =>
            if err?
                console.log("Error finding VPC and LB stacks: #{err}")
                cb(err, null, null) if cb?
                return

            stacks = data.Stacks
            vpc = _.find stacks, (s) =>
                (s.Tags.some (t) => t.Key == 'Environment' && t.Value == environment) and
                (s.Tags.some (t) => t.Key == 'Name' && t.Value == 'vpc')

            unless vpc?
                console.log("Error finding VPC stack: #{util.inspect(stacks)}")

            lb = _.find stacks, (s) =>
                (s.Tags.some (t) => t.Key == 'Environment' && t.Value == environment) and
                (s.Tags.some (t) => t.Key == 'Name' && t.Value == 'load-balancers')

            unless lb?
                console.log("Error finding load balancer stack: #{util.inspect(stacks)}")

            cb(null, vpc, lb) if cb?

    _checkCancel: (appVersions, environment) ->
        history = @getHistory appVersions[0], environment
        return _.find(history, (status) -> status.status == 'Deploy canceled')?

    _recordDeploy: (appVersions, environment, token) ->
        appVersions.forEach (item) =>
            name = item.Name
            if item.Version.indexOf('v') == 0
                version = item.Version
            else
                version = "v#{item.Version}"

            @_getSHA name, version, token, (sha) ->

                console.log "Writing #{name} #{version} deploy to Github"
                options =
                    url: "https://api.github.com/repos/" + organizationName + "/#{name}/deployments",
                    headers:
                        'User-Agent': 'request',
                        'Authorization': "token #{token.key}",
                        'Accept': 'application/vnd.github.cannonball-preview+json'
                    json:
                        ref: sha || version,
                        environment: environment,
                        auto_merge: false

                request.post options, (err, res, body) ->
                    if err?
                        console.log "Error reaching github api: #{err}" 
                    else
                        console.log "Write to github complete"

                    unless sha?
                        sha = JSON.parse(body).sha
                        
                    console.log "Writing #{name} #{version} deploy to Rollbar"
                    accessToken = rollbarAccessTokens[name]
                    if access_token? and sha?
                        options =
                            url: "https://api.rollbar.com/api/1/deploy/"
                            json:
                                'access_token': access_token,
                                'environment': environment,
                                'revision': sha,
                                'local_username': token.github,
                                'comment': version
                        request.post options, (err, res, body) ->
                            return console.log "Error reaching rollbar api: #{err}" if err?
                            console.log "Write to Rollbar complete"
    _getSHA: (name, version, token, cb) ->
        options =
            url: "https://api.github.com/repos/" + organizationName + "/#{name}/git/refs/tags/#{version}"
            headers:
                'User-Agent': 'request',
                'Authorization': "token #{token.key}",
                'Content-Type': 'application/json'
        request options, (err, res, body) ->
            if err?
                console.log "Error reaching github api: #{err}"
                cb null
            sha = JSON.parse(body).object.sha if JSON.parse(body).object?
            unless sha?
                cb null
            options =
                url: "https://api.github.com/repos/" + organizationName + "/#{name}/git/tags/#{sha}"
                headers:
                    'User-Agent': 'request',
                    'Authorization': "token #{token.key}",
                    'Content-Type': 'application/json'
            request options, (err, res, body) ->
                if err?
                    console.log "Error reaching github api: #{err}"
                    cb null

                sha = JSON.parse(body).object.sha if JSON.parse(body).object?
                cb sha



