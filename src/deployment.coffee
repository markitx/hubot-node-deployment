# Description:
#   Deploy software from hubot
#
# Dependencies:
#   None
#
# Commands:
#   hubot setup github token <token> - Adds user's github token to S3
#   hubot bastion info [environment] - Returns info about bastion hosts running in an environment
#   hubot bastion start [environment] - Starts any unrunning bastion hosts in an environment
#   hubot bastion stop [environment] - Stops any unrunning bastion hosts in an environment
#   hubot deploy <application> <version> to <environment> [debug] - Deploys the specified application with the specified version to the specified environment. Specifying debug at the end will leave failed stacks in place
#   hubot cancel <application> <version> to <environment> - Cancel a deploy (Does not work with deploy-multiple)
#   hubot history <application> <version> in <environment> - Get the history of status for a deploy
#   hubot status <application> <version> in <environment> - Get the latest status for a deploy
#   hubot destroy <application> <version> in <environment> - Finds a specific deployed version and, if found, deletes that deployment. Will only work if the deploy being destroyed failed.
#   hubot deploy-multiple [<application> <version>, <application> <version>, ...] to <environment> [debug] - Deploys the specified application with the specified version to the specified environment. Specifying debug at the end will leave failed stacks in place
#   hubot clean-up <application> in <environment> - Terminates all other versions of application in environment.  Use after making sure your deploy looks good
#   hubot cleanup <application> in <environment> - Terminates all other versions of application in environment.  Use after making sure your deploy looks good
#   hubot rollback <application> in <environment> - Rolls back to the previous version of the application that was deployed
#   hubot version <application> [in <environment>] - Prints out the currently deployed version of application.  environment defaults to production
#   hubot preserve <application> in <environment> - Prevents automatic cleanup of this application.
#   hubot add-dev-ip <ipaddress> [persist] - Authorize access to development network for 24 hours, optionally persisting for an indefinite period of time
#   hubot add dev ip <ipaddress> [persist] - Authorize access to development network for 24 hours, optionally persisting for an indefinite period of time
#   hubot remove-dev-ip <ipaddress> - Deauthorize access to development network.
#   hubot remove dev ip <ipaddress> - Deauthorize access to development network.
#
# Configuration:
#
#   HUBOT_DEPLOYMENT_AWS_KEY_NAME
#   HUBOT_DEPLOYMENT_BUCKET
#   HUBOT_DEPLOYMENT_GITHUB_TOKEN
#   HUBOT_DEPLOYMENT_GITHUB_ORGANIZATION
#   
# Notes:
#   HUBOT_DEPLOYMENT_AWS_KEY_NAME is ssl key used to secure instances
#   HUBOT_DEPLOYMENT_BUCKET is the S3 bucket used to store deployment tarballs after downloading from Github and npm installing
#   HUBOT_DEPLOYMENT_GITHUB_TOKEN is the Github API token used to download source code
#   HUBOT_DEPLOYMENT_GITHUB_ORGANIZATION is the organization/user that the code lives in
#   
# URLS:
#
# Author:
#   dylanlingelbach

_ = require('underscore')
AWS = require('aws-sdk')
request = require('request')
moment = require('moment')

util = require('util')

Bastion = require('../lib/bastion')
Deployment = require('../lib/deployment')

deployer = new Deployment()
bastion = new Bastion()
s3 = new AWS.S3()

tokenBucket = process.env.HUBOT_DEPLOYMENT_TOKEN_BUCKET;
defaultTokenUser = process.env.HUBOT_DEPLOYMENT_DEFAULT_TOKEN_USER;

getEnvironment = (environment) ->
  return environment if environment
  return 'production'


getSendToRoom = (msg) ->
  room = msg.envelope.user.reply_to
  return (message) ->
    msg.envelope.user.reply_to = room
    return msg.send message

getTokens = (cb) ->
  parems = 
    Bucket: tokenBucket,
    Key: 'hubot-deployment.json'
  s3.getObject parems, (err, data) ->
    if err?
      console.log "Error retrieving tokens from s3: #{err}"
      cb {}
    cb JSON.parse(data.Body.toString())

putToken = (new_tokens, cb) ->
  parems = 
    Bucket: tokenBucket,
    Key: 'hubot-deployment.json',
    ContentType: "application/json",
    Body: new Buffer(JSON.stringify(new_tokens,null,2))
  s3.putObject parems, (err, data) ->
    console.log "Error putting tokens in s3: #{err}" if err?
    cb err
  

module.exports = (robot) ->
  getTokens (tokens) ->

    robot.respond /deploy (.+) (.*) to ([^\s]+)\s*(debug)?/i, (msg) ->
      application = escape(msg.match[1].trim())
      version = escape(msg.match[2].trim())
      environment = escape(msg.match[3].trim())
      debug = escape(msg.match[3].trim()) == 'debug'

      sendToRoom = getSendToRoom(msg)

      unless application? and version? and environment?
        return sendToRoom("Usage: deploy <application> <version> to <environment>")

      user = msg.envelope.user.name
      token = tokens[user]

      unless token? and token.github? and token.key?
        sendToRoom("Usage: No github token is attached to #{user}.  Send a private message to Adam using the command \'setup github token <token>\' with a github token with scopes repo, user, repo_deployment")
        token = _.clone(tokens[defaultTokenUser])
        token.github = user
      appVersion =
        Name: application,
        Version: version
      pushStatus = deployer._getPushStatus [appVersion], environment
      events = deployer.deploy environment, application, version, token, debug, (err, data) ->
        if err?
          errorMessage = "Error deploying #{application} #{version} to #{environment}: #{err}"
          pushStatus errorMessage
          return sendToRoom(errorMessage)
        sendToRoom("Now deploying #{application} #{version} to #{environment}")

      if events
        events.on 'complete', (stackId) ->
          sendToRoom("Deployment of #{application} #{version} to #{environment} ready, adding to load balancer")
          pushStatus "Deployment complete"

        events.on 'error', (stackId) ->
          sendToRoom("Deployment of #{application} #{version} to #{environment} failed")

        events.on 'live-in-elb', () ->
          sendToRoom("Deployment of #{application} #{version} to #{environment} complete")

        events.on 'cleanup', (environment, application) ->
          console.log "Now cleaning up #{application} in #{environment}"
          sendToRoom("@#{robot.name} cleanup #{application} in #{environment}")
          deployer.cleanUp environment, application, (err, data) ->
            if err
              sendToRoom("Unable to remove old versions: #{err}")
            else
              sendToRoom("Removing all old versions of #{application} in #{environment}")


        sendToRoom("Deployment of #{application} #{version} to #{environment} starting")

    robot.respond /add[-| ]dev[-| ]ip (\d{1,3}.\d{1,3}.\d{1,3}.\d{1,3}) ?(persist)?/, (msg) ->
      sendToRoom = getSendToRoom(msg)

      ipAddress = msg.match[1].trim()
      persist = msg.match[2]? 
      user = msg.envelope.user.name

      deployer.addDevIp ipAddress, persist, user, (err, lb) ->
        if err
          sendToRoom "Failed to add ip #{ipAddress}: #{err}"
        else if persist
          sendToRoom "Authorized #{ipAddress} access to development for an indefinite period of time."
        else
          sendToRoom "Authorized #{ipAddress} access to development for 24 hours."

    robot.respond /remove[-| ]dev[-| ]ip (\d{1,3}.\d{1,3}.\d{1,3}.\d{1,3})/, (msg) ->
      sendToRoom = getSendToRoom(msg)

      ipAddress = msg.match[1].trim()

      deployer.removeDevIp ipAddress, (err, lb) ->
        if err
          sendToRoom "Failed to remove ip #{ipAddress}: #{err}"
        else
          sendToRoom "Deauthorized #{ipAddress}'s access to development."


    robot.respond /deploy-multiple \[(.+)\] to ([^\s]+)\s*(debug)?/i, (msg) ->
      applications = msg.match[1].trim()
      environment = msg.match[2].trim()

      debug = msg.match[3].trim() == 'debug'

      sendToRoom = getSendToRoom(msg)

      unless applications? and environment?
        return sendToRoom("Usage: deploy-multiple [<application> <version>, <application> <version>, ...] to <environment>")

      user = msg.envelope.user.name
      token = tokens[user]

      unless token? and token.github? and token.key?
        sendToRoom("Usage: No github token is attached to #{user}.  Private message \'setup github token <token>\' to adam with a github token with scopes repo, user, repo_deployment")
        token = _.clone(tokens[defaultTokenUser])
        token.github = user

      applications = applications.split(',')

      appVersions = applications.map (a) -> 
        appVersion = a.trim().split(' ')
        { Name: appVersion[0], Version: appVersion[1] }

      getDeployString = (versions) -> (versions.map (av) -> "#{av.Name}-#{av.Version}").join(',')

      events = deployer.deployMultiple environment, appVersions, token, debug, (err, data) ->
        versions = data || appVersions
        deployString = getDeployString(versions)
        return sendToRoom("Error deploying #{deployString} to #{environment}: #{err}") if err?

        sendToRoom("Deploying #{deployString} to #{environment}")

      if events
        events.on 'complete', (stackId, applications) ->
          versions = _.filter(appVersions, (av) => _.contains(applications, av.Name))
          sendToRoom("Deployment of #{getDeployString(versions)} to #{environment} complete")

        events.on 'error', (stackId, applications) ->
          versions = _.filter(appVersions, (av) => _.contains(applications, av.Name))
          sendToRoom("Deployment of #{getDeployString(versions)} to #{environment} failed")
        sendToRoom("Deployment of #{getDeployString(appVersions)} starting")

    robot.respond /rollback (.+) in (.+)/i, (msg) ->
      application = msg.match[1].trim()
      environment = msg.match[2].trim()
      sendToRoom = getSendToRoom(msg)

      unless application? and environment?
        return sendToRoom("Usage: rollback <application> in <environment>")

      deployer.rollback environment, application, (err, data) ->
        sendToRoom("Rolled back #{application} in #{environment}")

    robot.respond /preserve (.+) in (.+)/i, (msg) ->
      application = msg.match[1].trim()
      environment = msg.match[2].trim()
      sendToRoom = getSendToRoom(msg)

      unless application? and environment?
        return sendToRoom("Usage: preserve <application> in <environment>")

      deployer.preserve environment, application, (err, data) ->
        sendToRoom("Preserved #{application} in #{environment}")

    robot.respond /destroy (.+) (.*) in (\w+)/i, (msg) ->
      application = escape(msg.match[1].trim())
      version = escape(msg.match[2].trim())
      environment = escape(msg.match[3].trim())
      sendToRoom = getSendToRoom(msg)
      unless application? and version? and environment?
        return sendToRoom("Usage: destroy <application> <version> in <environment>")

      deployer.destroyDeploy environment, application, version, (err, data) ->
        if err?
          sendToRoom("Failed to destroy #{application} #{version} in #{environment}: #{err}")
        else
          sendToRoom("Destroyed #{application} #{version} in #{environment}")

    robot.respond /version (\S+)(?: in )?(\S+)?/i, (msg) ->
      application = msg.match[1]
      environment = msg.match[2] || 'production'
      sendToRoom = getSendToRoom(msg)

      unless application? and environment?
        return sendToRoom("Usage: version <application> [in <environment>]")

      deployer.getVersion environment, application, (err, data) ->
        if err? 
          return sendToRoom("Can't find version of #{application} in #{environment}: #{err}")

        cleanedUp = if data.cleanedUp then "" else "It has NOT been cleaned up.  Uncleaned versions: #{data.uncleanedVersions.join(', ')}"

        sendToRoom("#{application} is running #{data.version} in #{environment}. #{cleanedUp}")

    robot.respond /clean-?up (.+) in (.+)/i, (msg) ->
      application = msg.match[1].trim()
      environment = msg.match[2].trim()
      sendToRoom = getSendToRoom(msg)

      unless application? and environment?
        return sendToRoom("Usage: clean-up <application> <version> in <environment>")

      deployer.cleanUp environment, application, (err, data) ->
        if err
          sendToRoom("Unable to remove old versions: #{err}")
        else
          sendToRoom("Removing all old versions of #{application} in #{environment}")

    robot.respond /bastion info ?(.*)/i, (msg) ->
      environment = getEnvironment(msg.match[1].trim())
      sendToRoom = getSendToRoom(msg)

      bastion.find environment, (err, instances) ->
        return sendToRoom("Error looking up bastion info: #{err}") if err?

        instances = instances.filter (i) -> i.State.Name == 'running'

        if instances.length == 0
          return sendToRoom("No bastion hosts running. Try starting them with bastion start.")

        ipAddresses = _.pluck(instances, 'PublicIpAddress')

        sendToRoom("Use one of the following IP addresses to ssh into a box: #{ipAddresses}")

    robot.respond /bastion start ?(.*)/i, (msg) ->
      environment = getEnvironment(msg.match[1].trim())
      sendToRoom = getSendToRoom(msg)

      bastion.start environment, (err) ->
        if err?
          sendToRoom("Error starting bastion instances: #{err}")
        else
          sendToRoom("Bastion in #{environment} starting")

    robot.respond /bastion stop ?(.*)/i, (msg) ->
      environment = getEnvironment(msg.match[1].trim())
      sendToRoom = getSendToRoom(msg)

      bastion.stop environment, (err) ->
        if err?
          sendToRoom("Error stopping bastion instances: #{err}")
        else
          sendToRoom("Bastion in #{environment} stopping")

    robot.respond /setup github token (.*)/i, (msg) ->
      token = msg.match[1].trim()
      sendToRoom = getSendToRoom(msg)
      user = msg.envelope.user.name

      unless token?
        return sendToRoom("Usage: setup github token <token>")
      options =
        url: "https://api.github.com/user",
        headers:
          'User-Agent': 'request',
          'Authorization': "token #{token}"

      request options, (err, res, body) ->

        if err?
          console.log "Error reaching github api: #{err}"
          return sendToRoom("Error reaching github api: #{err}")
        if JSON.parse(body).message?
          console.log "Error: #{JSON.parse(body).message}"
          return sendToRoom("Error: #{JSON.parse(body).message}")
        if JSON.parse(body).login?
          tokens[user] =
            "github": JSON.parse(body).login,
            "key": token
          putToken tokens, (err) ->
            return sendToRoom("Error putting tokens in s3: #{err}") if err?
            sendToRoom("Successfully added github token")
    robot.respond /(status|history) (.+) (.*) in (.+)/i, (msg) ->
      command = msg.match[1]
      application = escape(msg.match[2].trim())
      version = escape(msg.match[3].trim())
      environment = escape(msg.match[4].trim())
      sendToRoom = getSendToRoom(msg)
      unless application? and version? and environment?
        return sendToRoom("Usage: #{command} <application> <version> in <environment>")
      appVersion =
        Name: application,
        Version: version
      history = deployer.getHistory(appVersion, environment)
      unless history?
        return sendToRoom("There is no deploy history for #{application} #{version} in #{environment}")
      switch command
        when 'status'
          status = _.last(history)
          sendToRoom("#{status.status} #{moment(status.time).fromNow()}")
        when 'history'
          sendMessage = (num) ->
            status = history[num]
            sendToRoom("[#{moment(status.time).toISOString()}] #{status.status} #{moment(status.time).fromNow()}")
            if history[num + 1]
              setTimeout((-> sendMessage(num + 1)), 100)
          sendMessage 0

    robot.respond /cancel (.+) (.*) to (.+)/i, (msg) ->
      application = escape(msg.match[1].trim())
      version = escape(msg.match[2].trim())
      environment = escape(msg.match[3].trim())
      sendToRoom = getSendToRoom(msg)
      unless application? and version? and environment?
        return sendToRoom("Usage: cancel <application> <version> to <environment>")

      appVersion =
        Name: application,
        Version: version
      history = deployer.getHistory(appVersion, environment)

      unless history?
        return sendToRoom("There is no deploy history for #{application} #{version} in #{environment}")
      pushStatus = deployer._getPushStatus [appVersion], environment
      if _.find(history, (status) -> status.status == 'Deployment complete')?
        return sendToRoom("Deployment of #{application} #{version} to #{environment} has already finished") 
      if _.find(history, (status) -> status.status == 'Deploy canceled')?
        return sendToRoom("Deployment of #{application} #{version} to #{environment} has already canceled")

      fullCancel = deployer.cancelDeploy appVersion, environment, (err, data) ->
        if err?
          errorMessage = "Error canceling deploy: #{err}"
          pushStatus errorMessage
          return sendToRoom(errorMessage)

        pushStatus 'Deploy canceled'
        sendToRoom("Deployment of #{application} #{version} to #{environment} canceling")

        if fullCancel
          filter = deployer.getEvents appVersion, environment
          filter.on 'delete', (stackId, applications) ->
            sendToRoom("Cancel of #{application} #{version} to #{environment} complete")
        else
          sendToRoom("Cancel of #{application} #{version} to #{environment} complete")










