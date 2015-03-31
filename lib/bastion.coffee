AWS = require('aws-sdk')
_ = require('underscore')

module.exports = class Bastion
    constructor: () ->
        @ec2 = new AWS.EC2

    start: (environment, cb) ->
        @find environment, (err, instances) =>
            cb(err, []) if err?
 
            instances = instances.filter (i) -> i.State.Name == 'stopped'

            if instances.length > 0
                @ec2.startInstances { InstanceIds: _.pluck(instances, 'InstanceId') }, (err, data) ->
                    cb(err, data)

    stop: (environment, cb) ->
        @find environment, (err, instances) =>
            cb(err, []) if err?
 
            instances = instances.filter (i) -> i.State.Name == 'running' or i.State.Name == 'pending'

            if instances.length > 0
                @ec2.stopInstances { InstanceIds: _.pluck(instances, 'InstanceId') }, (err, data) ->
                    cb(err, data)

    find: (environment, cb) ->
        @ec2.describeInstances { Filters: [ { Name: 'tag-key', Values: ['Bastion'] }, { Name: 'tag:Environment', Values: [environment] } ]  }, (err,data) ->
            if err?
                console.log("Error: #{err}")
                cb(err, []) if cb?
            cb(null, _.flatten(_.pluck(data.Reservations, 'Instances')).filter (i) -> i.State.Name != 'terminated') if cb?