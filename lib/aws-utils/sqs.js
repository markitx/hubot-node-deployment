/**
 * Wrapper library for SQS.
 * 
 * Receive messages through sqs.on('message', function (message, callback) {});
 * 
 * If callback is passed anything in the first arg, it will assume the message
 * was not successfully processed and will not delete it from the queue. If
 * you want messages deleted no matter what (read-once) set 
 * sqs.readOnceOnly to true. This will ensure messages are deleted
 * even if the message handler never invokes the callback.
 *
 * If callback is passed a second argument of type function, it will
 * call that function after confirming the triggering message has been
 * deleted from the queue.
 * 
 * sqs.maxConcurrency sets how many messages can be processed at once. 
 *  * Set to 1 (default) to guarentee in-order processing.
 *  * Set to 0 to have no limit on concurrent open messages.
 *
 * Listen to sqs.on('error', err) for errors while receiving messages
 *
 * Starts receiving messages as soon as the 'message' event is subscribed to
 *
 * Creates the queue with default properties if it doesn't already exist, 
 * emitting 'created' event. To check for existance first, call exists().
 * 
 */

var AWS = require('aws-sdk');
var util = require('util');
var events = require('events');
var uuid = require('node-uuid');
var async = require('async');

var AWS_SQS_API_VERSION = '2012-11-05';
var AWS_POLICY_AWS_SQS_API_VERSION = '2008-10-17';
var AWS_SNS_API_VERSION = '2010-03-31';

var MAX_CONCURRENT_MESSAGES = 20;
var SQS_WAIT_TIME_SECONDS = 20;
var MAX_VISIBILITY_TIMEOUT = 20000;

var SQS = function (queueName, sqsConfig) {
    this.queueName = queueName;
    this.sqsConfig = sqsConfig || { parse: JSON.parse }

    this.maxConcurrency = 1;
    this.visibilityTimeout = 15;
    this.initialized = false;
    this.readOnceOnly = false;
    this.sqs = null;
    this.queueUrl = null;

    this._openRequests = 0;
    this.paused = false;
    this._receiving = false;

    events.EventEmitter.call(this);

    var self = this;

    this.on('newListener', function (event) {
        if(event === 'message' && !self.paused && !self._receiving) {
            self.create(function (err) {
                if (err) {
                    self.emit('error', err);
                    return;
                }
                self._receiveMessage(true);
            });
        }
    });
};

util.inherits(SQS, events.EventEmitter);

SQS.prototype._invokeAfterInit = function(method, args) {
    var self = this;
    var argsArray = Array.prototype.slice.apply(args);
    var callback = function () {};
    if (argsArray.length > 0 && 'function' === typeof (argsArray[argsArray.length - 1])) {
        var userCallback = argsArray[argsArray.length - 1];
        callback = userCallback;
    }

    if (self.initialized) {
        return method.apply(self, argsArray);
    }
    self._getQueueUrl(function (err) {
        if (!err) {
            method.apply(self, argsArray);
            return;
        }

        if (err.code !== 'AWS.SimpleQueueService.NonExistentQueue') {
            err.message = 'Error getting url for queue ' + self.queueName + '\n' + err.message;
            callback(err);
            return;
        }

        self.sqs.createQueue({ QueueName: self.queueName }, function (err, data) {
            if (err) {
                err.message = 'Error creating queue ' + self.queueName + '\n' + err.message;
                callback(err);
                return;
            }
            self.queueUrl = data.QueueUrl;
            self.initialized = true;
            self.emit('created');
            method.apply(self, argsArray);
        });
    });
};

/**
 * Create the queue if it doesn't already exist
 * @param  {Function} callback callback(err)
 * @return {null}
 */
SQS.prototype.create = function (callback) {
    this._invokeAfterInit(this._create, arguments);
};

SQS.prototype._create = function (callback) {
    var self = this;

    if (callback) {
        callback();
    }
};

SQS.prototype.stop = function () {
    this.paused = true;
};

SQS.prototype._getQueueUrl = function (callback) {
    var self = this;

    if (this.queueUrl) {
        callback(null, self.queueUrl);
        return;
    }

    self.sqs = new AWS.SQS({ apiVersion: AWS_SQS_API_VERSION });
    self.sqs.getQueueUrl({ QueueName: self.queueName }, function (err, data) {
        if (err) {
            err.message = 'Error getting url for queue ' + self.queueName + '\n' + err.message;
            callback(err);
            return;
        }
        self.initialized = true;
        self.queueUrl = data.QueueUrl;
        callback(null, self.queueUrl);
    });
};

SQS.prototype.subscribeToSnsTopic = function (topicArn, callback) {
    this._invokeAfterInit(this._subscribeToSnsTopic, arguments);
};

SQS.prototype._subscribeToSnsTopic = function (topicArn, callback) {
    var self = this;

    var params = {
        QueueUrl: self.queueUrl,
        AttributeNames: ['All']
    };
    self.sqs.getQueueAttributes(params, function (err, data) {
        if (err) {
            err.message = 'Error subscribing queue ' + self.queueName +
                ' to topic ' + topicArn + '.\n' + err.message;
            callback(err);
            return;
        }
        var queueArn = data.Attributes.QueueArn;
        var originalPolicyRaw = data.Attributes.Policy;

        async.parallel([
            function (done) {
                // Subscribe SNS -> SQS if not already subscribed.
                var sns = new AWS.SNS({ apiVersion: AWS_SNS_API_VERSION });
                params = {
                    TopicArn: topicArn
                };

                sns.listSubscriptionsByTopic(params, function (err, data) {
                    if (err) {
                        err.message = 'Error checking sns subscriptions for ' + topicArn + '. \n' + err.message;
                        callback(err);
                        return;
                    }

                    if (data.Subscriptions.some(function (subscription) {
                        return subscription.Protocol === 'sqs' &&
                            subscription.Endpoint === queueArn;
                    })) {
                        // already subscribed
                        done();
                        return;
                    }

                    params = {
                        TopicArn: topicArn,
                        Protocol: 'sqs',
                        Endpoint: queueArn
                    };
                    sns.subscribe(params, function (err, data) {
                        if (err) {
                            err.message = 'Error subscribing qeueue ' + self.queueName + ' to sns topic ' +
                                topicArn + '\n' + err.message;
                            callback(err);
                            return;
                        }
                        done(null, data.SubscriptionArn);
                    });
                });
            }, function (done) {
                // Give write permission for SNS -> SQS if it doesn't already exist
                var snsSendPermission = {
                    Sid: uuid.v4(),
                    Effect: 'Allow',
                    Principal: {'AWS': '*'},
                    Action: 'SQS:SendMessage',
                    Resource: queueArn,
                    Condition: {
                        ArnEquals: {
                            "aws:SourceArn": topicArn
                        }
                    }
                };
                var originalPolicyStatements = [];
                if (originalPolicyRaw) {
                    try {
                        var originalPolicy = JSON.parse(originalPolicyRaw);

                        if (originalPolicy && Array.isArray(originalPolicy.Statement)) {
                            var match = originalPolicy.Statement.some(function (statement) {
                                return statement.Effect === snsSendPermission.Effect &&
                                    statement.Principal && statement.Principal.AWS === snsSendPermission.Principal.AWS &&
                                    statement.Action === snsSendPermission.Action &&
                                    statement.Resource === snsSendPermission.Resource &&
                                    statement.Condition && statement.Condition.ArnEquals &&
                                    statement.Condition.ArnEquals['aws:SourceArn'] ===
                                    snsSendPermission.Condition.ArnEquals['aws:SourceArn'];
                            });
                            if (match) {
                                done();
                                return;
                            }
                            originalPolicyStatements = originalPolicy.Statement;
                        }
                    } catch (ex) {
                        // Couldn't parse original policy, just try to create a new one
                        ex.message = 'Warning: Couldn\'t parse exising SQS Policy. \n' + (ex.message || '');
                        self.emit('error', ex);
                    }
                }
                originalPolicyStatements.push(snsSendPermission);
                var policyString = JSON.stringify({
                    Version: AWS_POLICY_AWS_SQS_API_VERSION,
                    Statement: originalPolicyStatements
                }, null, 2);
                var params = {
                    QueueUrl: self.queueUrl,
                    Attributes: {
                        Policy: policyString
                    }
                };
                self.sqs.setQueueAttributes(params, function (err) {
                    if (err) {
                        err.message = 'Error adding sendMessage permission from topic ' + topicArn +
                            ' to queue ' + self.queueUrl + '\n' + err.message;
                            done(err);
                    }
                    done();
                });
            }
            ], function (err) {
                callback(err);
            });
    });
};

SQS.prototype.exists = function (callback) {
    var self = this;

    if (self.queueUrl) {
        callback(null, true);
        return;
    }

    self._getQueueUrl(function (err) {
        callback(err, err !== null);
    });
};

SQS.prototype._receiveMessage = function (listenerAdded) {
    var self = this;
    if (self._receiving) {
        // Already have an open receive. Don't add another one.
        self.emit('status', 'Multiple open SQS receives for ' + self.queueName + '. Closing one poller.');
        return;
    }

    if (!listenerAdded && self.listeners('message').length === 0) {
        // Don't receive messages when there's nobody listening
        // self.listeners doesn't get updated until after the 'newListener' event handler returns
        self.emit('status', 'Last SQS listener has been removed for ' + self.queueName + '. Queue polling will cease ');
        return;
    }

    if (self.maxConcurrency > 0 && self.maxConcurrency === self._openRequests) {
        // Don't wait for more messages if we're already at max concurrency
        self.emit('status', 'Max SQS concurrency has been exceeded for ' + self.queueName + '. Closing one poller.');
        return;
    }

    var receiveParams = {
        QueueUrl: self.queueUrl,
        MaxNumberOfMessages: Math.min(Math.max(1, self.maxConcurrency - self._openRequests), 10),
        WaitTimeSeconds: SQS_WAIT_TIME_SECONDS,
        VisibilityTimeout: self.visibilityTimeout
    };
    self._receiving = true;
    self.sqs.receiveMessage(receiveParams, function (err, data) {
        self._receiving = false;
        if (err) {
            self.emit('error', err);
            // TODO: We want to return here if the error is unrecoverable, but otherwise keep trying.
        }
        if (data === null || !data.Messages || data.Messages.length === 0) {
            // setTimeout(function() {
                self._receiveMessage();
            // }, SQS_WAIT_TIME_SECONDS * 1000);
            return;
        }

        // See if anyone's listening. If not, or if paused make the message visible again asap
        var listeners = self.listeners('message');
        if (!listeners || listeners.length === 0 || self.paused) {
            var visibleParams = {
                QueueUrl: self.queueUrl,
                Entries: data.Messages.map(function (message, index) {
                    return {
                        Id: '' + index,
                        ReceiptHandle: message.ReceiptHandle,
                        VisibilityTimeout: 0
                    };
                })
            };
            self.sqs.changeMessageVisibilityBatch(visibleParams, function (err) {
                if (err) {
                    self.emit('error', err);
                }
            });
            return;
        }

        data.Messages.forEach(function (rawMessage) {
            var receiptHandle = null;
            var messageParsed = false;
            try {
                var message = JSON.parse(rawMessage.Body);
                receiptHandle = rawMessage.ReceiptHandle;
                var subject = message.Subject;
                // TODO: Check MD5 of body?

                if (self.readOnceOnly) {
                    self._deleteMessage(receiptHandle);
                }

                if (message.Type === 'Notification') {
                    message = self.sqsConfig.parse(message.Message);
                    message.subject = message.subject || subject;
                }
                messageParsed = true;
                self._incrementOpenRequests();
                var hadListeners = self.emit('message', message, function (err, deleteConfirmCallback) {
                    if (self.readOnceOnly) {
                        // if they want to use the callback, just ignore it
                        return;
                    }
                    self._decrementOpenRequests();

                    if (err) {
                        err.message = 'Error in on message handler for queue ' + self.queueName + '.\n' +
                            err.message;
                        self.emit('error', err);
                        return; // don't delete the message because it wasn't actually handled
                                // or it was already deleted
                    }
                    self._deleteMessage(receiptHandle, deleteConfirmCallback);
                });
                if(!hadListeners) {
                    // message had no listeners, so decrement back open request count
                    self._decrementOpenRequests();
                }
            } catch (ex) {
                // set message visibility to max value so we don't just spin on this error
                // but leave the message there so admins or others can look at it.
                var visibilityParams = {
                    ReceiptHandle: receiptHandle,
                    QueueUrl: self.queueUrl,
                    VisibilityTimeout: MAX_VISIBILITY_TIMEOUT
                };
                self.sqs.changeMessageVisibility(visibilityParams, function (err, data) {
                    if (err) {
                        err.Message = 'Error setting visibility timeout to hide malformed message.\n' + err.Message;
                        self.emit('error', err);
                    }
                });
                var err = ex;
                if (!messageParsed) {
                    err = new Error('Malformed message in queue "' + self.queueName + '" .' + (ex.Message ? '\n' + ex.Message : ''));
                }
                self.emit('error', err);
            }
        });
    });
};

SQS.prototype._incrementOpenRequests = function() {
    // we're not requiring callbacks if readOnceOnly is set,
    // so don't track openRequests
    if (!this.readOnceOnly) {
        this._openRequests++;
    }
};

SQS.prototype._decrementOpenRequests = function() {
    // we're not requiring callbacks if readOnceOnly is set,
    // so don't track openRequests
    if (!this.readOnceOnly) {
        this._openRequests--;
    }
};

SQS.prototype._deleteMessage = function (receiptHandle, deleteConfirmCallback) {
    var self = this;

    var deleteParams = {
        QueueUrl: self.queueUrl,
        ReceiptHandle: receiptHandle
    };
    self.sqs.deleteMessage(deleteParams, function (err) {
        if (!self._receiving) {
            self._receiveMessage();
        }
        if ('function' === typeof (deleteConfirmCallback)) {
            deleteConfirmCallback();
        }

        if (err) {
            self.emit('error', err);
            return;
        }

    });
};

SQS.prototype.sendMessage = function (message, callback) {
    this._invokeAfterInit(this._sendMessage, arguments);
};

SQS.prototype._sendMessage = function (message, callback) {
    var self = this;

    var sendParams = {
        QueueUrl: self.queueUrl,
        MessageBody: JSON.stringify(message)
    };
    self.sqs('sendMessage', sendParams, function (err) {
        // TODO: Check MD5?
        callback(err);
    });
};

SQS.prototype.sendMessageBatch = function (messages, callback) {
    this._invokeAfterInit(this._sendMessageBatch, arguments);
};

SQS.prototype._sendMessageBatch = function (messages, callback) {
    var self = this;

    var sendParams = {
        QueueUrl: self.queueUrl,
        Entries: messages.map(function (message, index) {
            return {
                Id: '' + index, // unique within this request
                MessageBody: JSON.stringify(message)
            };
        })
    };

    self.sqs.sendMessage(sendParams, function (err, data) {
        // TODO: Check MD5?
        if (err) {
            err.message = 'Error sending message batch in queue ' + self.queueName +
                '\n' + err.message;
            callback(err);
        } else if (data.Failed && data.Failed.length > 0) {
            err = new Error('Some messages in batch were not written to the queue. See err.failedMessages');
            err.failedMessages = data.Failed;
            callback(err);
        } else {
            callback();
        }
    });
};

SQS.prototype.setAttributes = function (attributes, callback) {
    this._invokeAfterInit(this._setAttributes, arguments);
};

SQS.prototype._setAttributes = function (attributes, callback) {
    var self = this;

    self.sqs.setQueueAttributes({
        QueueUrl: self.queueUrl,
        Attributes: attributes
    }, callback);
};

SQS.prototype.getAttributes = function (callback) {
    this._invokeAfterInit(this._getAttributes, arguments);
};

SQS.prototype._getAttributes = function (callback) {
    var self = this;

    self.sqs.getQueueAttributes({
        QueueUrl: self.queueUrl,
        AttributeNames: ['All']
    }, function (err, data) {
        callback(err, data ? data.Attributes : null);
    });
};

module.exports = SQS;