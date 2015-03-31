_ = require('underscore')

events = require('events')
util = require('util')

module.exports = class EventFilter
    constructor: (@eventListener) ->
        @stacksToApplications = {}

        @eventListener.on 'event', (stackId, status, event) =>
            @_filter(stackId, status, event)

        @events = new events.EventEmitter

    addStack: (stackId, appVersions) ->
        @stacksToApplications[stackId] = appVersions

    on: (event, args...) ->
        @events.on event, args...

    emit: (event, args...) ->
        @events.emit event, args...

    _filter: (stackId, status, event) ->
        appVersions = @stacksToApplications[stackId]
        unless appVersions?
            return

        applications = _.pluck(appVersions, 'Name')

        if status == 'CREATE_COMPLETE'
            @emit('complete', stackId, applications)
        else if status == 'ROLLBACK_COMPLETE'
            @emit('error', stackId, applications)
        else if status == 'DELETE_COMPLETE'
            @emit('delete', stackId, applications)
            
        




