#!/usr/bin/env coffee
{ _ } = require 'lodash'
async = require 'async'
log   = require 'node-logging'

config = require './config.coffee' # config
jb     = require './db.coffee'     # db handle
jobs   = require './jobs.coffee'   # jobs to run from config
mailer = require './mailer.coffee' # mailer
utils  = require './utils.coffee'  # utilities
date   = require './date.coffee'   # date utilities
job    = require './job.coffee'    # run one job
app    = require './api.coffee'    # api app

# Start flatiron dash app.
async.waterfall [ app

# Integrity check.
, (cb) ->
    # For all current jobs, get their latest later than cutoff.
    jb.find 'latest',
        # 3m behind last timeout.
        time:
            $lt: + new Date - ( (config.timeout + 3) * 6e4 )
        # Remove them at the same time.
        $dropall: yes
    , _.partial utils.arrayize, cb

# Message if we were down.
, (arr, cb) ->
    # Filter down to jobs we currently know.
    arr = utils.known arr

    return cb null if !arr.length # we did not know any of them

    log.dbg "#{arr.length} jobs are behind schedule"

    # Templatize
    async.parallel [
        _.partial config.email.templates.subject, { name: 'apptime process', verb: 'was', status: 'DOWN' }
        _.partial config.email.templates.integrity,
            # Since the latest status update.
            since: date.format _.max(arr, 'time').time, 'HH:mm:ss on ddd'
    ], (err, email) ->
        return cb err if err
        # Mail it.
        mailer email, cb

# Start monitoring.
], (err) ->
    throw err if err
    log.dbg 'apptime'.bold + ' dashboard online'

    # All jobs in parallel...
    q = async.queue (noop, done) ->
        log.dbg 'Running a batch'        
        job.errors([]) # clear all previous errors
        async.each jobs, job.one, ->
            log.dbg 'Batch done'
            done null
    , 1 # ... with concurrency of 1...

    # ...now.
    do run = _.bind q.push, null, {} # passing array to q.push != one job

    # ... and in the future.
    setInterval run, config.timeout * 6e4