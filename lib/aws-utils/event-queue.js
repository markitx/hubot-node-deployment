/**
 * EventQueue is an abstraction around SNS and SQS that allows events to be sent
 * and processed asynchronously, including fan-out and batching patterns.
 *
 * EventQueue.name can only contain upper- and lower-case letters and numbers.
 *
 * Don't share queues between EventQueues and other consumers! Messages not sent from an
 * event queue with matching queue id will be deleted un-read.
 *
 * EventQueue components are named by convention, based on the name passed to the constructor. 
 *
 *     * env-prefix = NODE_ENV 
 *     * queue-name = env-prefix + name
 *     * sns-topic = queue-name
 *     * sqs-queue = queue-name
 *
 * If configured with batch mode (options.batchSeconds > 0), two additional components are created:
 * 
 *     * sqs-delayed-queue = <queue-name>-delayed
 *     * simpledb-events = <queue-name>-pending-batches
 *
 * For example, a queue named "orders" in "development" the environment with 15-minute batching 
 * enabled would have the following AWS components:
 *
 *     * SNS Topic:  "development-orders-events"
 *     * SQS Queue:  "development-orders-events"
 *     * SQS Queue:  "development-orders-events-delayed"
 *     * DDB Table:  "pending-events"
 *
 * Events
 * ======
 * 
 * eq.on('event', event, callback)
 *
 * eq.on('event-batch', events, callback)
 * 
 * eq.on('error', error)
 *
 */

var AWS = require('aws-sdk');
var util = require('util');
var events = require('events');
var async = require('async');
var uuid = require('node-uuid');

var SQS = require('./sqs');

var LIMITED_RESOURCES = ['sns'];

var getEnvironmentPrefix = function (uniqueDev) {
    var env = (process.env.NODE_ENV || 'development').toLowerCase();
    if (uniqueDev && (env === 'development' || env === 'test')) {
        return env + '-' + (process.env.USER || 'NAUSER').slice(0,8) + '-';
    }
    return env + '-';
};

/**
 * Gets the fully-qualified name of a component based on the group name,
 * component name and environment.
 * @param  {string} type      type of component ('sns', 'sqs', 'sdb', etc)
 * @param  {string} group     name of the group of components
 * @param  {string} component (optional) name of this component
 * @return {string}           fully-qualified name
 */
var getName = function (type, group, component) {
    // SNS resources don't get unique dev names because
    // they are limited to 100 per user. Instead we fan
    // out to uniquely named SQS queues then ignore
    // any messages not really meant for that queue.
    var uniqueDev = LIMITED_RESOURCES.indexOf(type.toLowerCase()) < 0;
    var envPrefix = getEnvironmentPrefix(uniqueDev);
    return envPrefix + group + (component ? '-' + component : '');
};

/**
 * Create a new event queue
 * @param  {object|string} options   name of event, or options object
 * @return {null}           
 */
var EventQueue = function (options) {

    this.name = options;
    this.components = {};
    this._componentsCreated = false;
    this._started = false;
    this.subQueueName = undefined;

    if ('object' === typeof (options)) {
        this.name = options.name;
        this.subQueueName = options.subQueueName;
        this.config = options;
    }

    this.groupName = this.name + '-events';
    this.eventQueueId = getName('event-queue', this.groupName, this.subQueueName);
    this.baseEventQueueId = getName('event-queue', this.groupName);

    events.EventEmitter.call(this);

    var self = this;

    this.on('newListener', function (event) {
        if(event === 'event' || event === 'event-batch') {
            if (self._componentsCreated) {
                self._start();
                return;
            }

            self._create(function (err) {
                if (err) {
                    self.emit('error', err);
                    return;
                }
                self._start();
            });
        }
    });
};

util.inherits(EventQueue, events.EventEmitter);

/**
 * Creates the AWS event queue components if they don't already exist
 * Idempotent
 * @param  {Function} callback callback(err, components)
 * @return {null}
 */
EventQueue.prototype._create = function (callback) {
    var self = this;

    async.parallel([
        function (done) {
            // Create the SNS Topic
            if (self.components.topic) {
                return done();
            }
            var snsName = self.config.snsTopic || getName('sns', self.groupName);
            var sns = new AWS.SNS();
            sns.createTopic({ Name: snsName }, function (err, data) {
                if (err) {
                    err.message = 'Error creating sns topic ' + snsName +
                        ' for event queue ' + self.name + '\n' + err.message;
                    return done(err);
                }
                self.components.topic = {
                    sns: sns,
                    topicArn: data.TopicArn
                };
                done();
            });
        }, function (done) {
            // Create the SQS Queue
            if (self.components.mainQueue) {
                return done();
            }
            var sqsName = self.eventQueueId;
            var sqs = new SQS(sqsName, self.config.sqsConfig);
            sqs.on('error', function (err) {
                self.emit('error', err);
            });
            sqs.on('info', function (msg) {
                self.emit('info', msg);
            });
            self.components.mainQueue = {
                sqs: sqs,
                subscribedToTopic: false
            };
            sqs.create(done);
        }
        ], function (err) {
            if (err) {
                callback(err);
                return;
            }
            self._componentsCreated = true;
            self._createSubscriptions(callback);
        }
    );
};

EventQueue.prototype._createSubscriptions = function (callback) {
    var self = this;
    async.parallel([
        function (done) {
            // Create main SNS -> SQS subscription
            self.components.mainQueue.sqs.subscribeToSnsTopic(self.components.topic.topicArn, function (err, data) {
                if (err) {
                    return done(err);
                }
                self.components.mainQueue.subscribedToTopic = true;
                done();
            });
        }, function (done) {
            // Create any additional requested SNS -> SQS subscriptions
            var topics = [].concat(self.config.topics || []);
            var eventTopics = [].concat(self.config.eventTopics || []);
            topics = topics.concat(eventTopics.map(function (name) {
                return getName('sns', name + '-events');
            }));
            self.components.topics = {};
            // Add the subscriptions one at a time so permissions aren't overwritten
            // TODO: Allow an array of topic arns to subscribe to in SQS
            async.eachSeries(topics, function (topic, cb) {
                var sns = new AWS.SNS();
                sns.createTopic({ Name: topic }, function (err, data) {
                    if (err) {
                        return cb(err);
                    }
                    var arn = data.TopicArn;
                    self.components.mainQueue.sqs.subscribeToSnsTopic(arn, function (err) {
                        if (err) {
                            return cb(err);
                        }
                        self.components.topics[topic] = {
                            topicArn: arn
                        };
                        cb();
                    });
                });
            }, done);
        }
        ], function (err) {
            callback(err);
        }
    );

};

/**
 * Start processing events from the queue, create if needed
 * @param  {Function} callback callback(err)
 * @return {null}
 */
EventQueue.prototype._start = function (callback) {
    var self = this;

    if (self._started) {
        if (callback) {
            callback();
        }
        return;
    }

    // read and fire events from the main queue
    self.components.mainQueue.sqs.on('message', function (message, cb) {
        // Allow messages for this queue or if no queue is specified
        if (message && (!message.queueId || message.queueId === self.baseEventQueueId)) {
            self.emit('event', message, cb);
        } else {
            // message destined for a different queue (but using same sns)
            cb(); // consume the message
        }
    });
    self._started = true;
    if (callback) {
        callback();
    }
};

/**
 * Stop reading events from the event queue
 * @return {[type]} [description]
 */
EventQueue.prototype.stop = function () {
    var self = this;
    var components = self.components;
    if (components.mainQueue && components.mainQueue.sqs) {
        components.mainQueue.sqs.stop();
    }
};

/**
 * publish a new event into the queue, create if needed
 * @param  {object} event event object
 * @param  {Function} callback callback(err, confirmation)
 * @return {null}
 */
EventQueue.prototype.publish = function (event, subject, callback) {
    var self = this;

    if ('function' === typeof (subject)) {
        callback = subject;
        subject = self.name;
    } else if (!callback) {
        callback = function () {};
    }

    var components = self.components;

    if (components.topic && components.mainQueue && components.mainQueue.subscribedToTopic) {
        return self._publish(event, subject, callback);
    }

    self._create(function (err) {
        if (err) {
            return callback(err);
        }
        self._publish(event, subject, callback);
    });
};

EventQueue.prototype._publish = function (event, subject, callback) {
    var self = this;

    var envelope = {
        eventId: uuid.v4(),
        name: self.name,
        subject: subject,
        queueId: self.eventQueueId,
        timestamp: new Date().toISOString(),
        body: event
    };
    var snsTopic = self.components.topic;

    var params = {
        TopicArn: snsTopic.topicArn,
        Subject: subject,
        Message: JSON.stringify(envelope)
    };

    console.log("Sending event to queue " + self.name + " with subject " + subject);

    self.components.topic.sns.publish(params, function (err, data) {
        callback(err, data ? data.MessageId : null);
    });
};

module.exports = EventQueue;