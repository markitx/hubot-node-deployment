fs = require('fs')
exec = require('child_process').exec
request = require('request')
AWS = require('aws-sdk')
moment = require('moment')
rimraf = require('rimraf')

s3 = new AWS.S3

organizationName = process.env.HUBOT_DEPLOYMENT_GITHUB_ORGANIZATION
githubToken = process.env.HUBOT_DEPLOYMENT_GITHUB_TOKEN
deploymentBucket = process.env.HUBOT_DEPLOYMENT_BUCKET

module.exports = class GitHubToS3 
    constructor: (@appName,@version) ->
        @tempPath = "/tmp/"
        @appPath = "#{@tempPath}#{@appName}-#{@version}"
        @appVersion = "#{@appName}-#{@version}"
        @tarFile = "#{@appVersion}.tar.gz"
        @tarPath = "#{@tempPath}#{@tarFile}"

        if @version.indexOf('v') == 0
            url = "https://api.github.com/repos/" + organizationName + "/#{@appName}/tarball/#{@version}"
        else
            url = "https://api.github.com/repos/" + organizationName + "/#{@appName}/tarball/v#{@version}"
        @options = 
            url: url,
            headers: 
                'User-Agent': 'request'

        @options.headers.Authorization = "token #{githubToken}"


    _cleanUp: (cb) ->
        rimraf @appPath, (err) =>
            if err?
                cb(err) if cb?
                return
            console.log("Cleaned up #{@appPath}")
            cb() if cb

    _sendToS3: (cb) ->
        fs.readFile @tarPath, (err, data) =>
            if err?
                cb(err) if cb?
                return
            console.log("Uploading #{@tarPath} to S3")
            s3.putObject
                ACL: 'private',
                Body: data,
                Bucket: deploymentBucket,
                Key: "#{@appName}/#{@tarFile}"
            ,(err, data) =>
                if err?
                    cb(err) if cb?
                    return
                console.log("Uploaded #{@tarPath} to S3")
                cb() if cb

    _existsOnS3: (cb) ->
        s3.getObject
            Bucket: deploymentBucket,
            Key: "#{@appName}/#{@tarFile}"
        ,(err,data) =>
            cb(data?)

    _downloadFromGithub: (pushStatus, cb) ->
        fs.mkdir @tempPath, (err) =>
            req = request(@options)

            req.on 'response', (res) =>
                if res.statusCode == 404
                    console.log("No tag v#{@version} found for #{@appName}. Did you tag and push that tag?")
                    cb("No tag v#{@version} found for #{@appName}")
                    return
                if res.statusCode != 200
                    console.log("Could not fetch #{@appName} #{@version} from Github: #{res.message} #{res.statusCode}")
                    cb("Could not fetch #{@appName} #{@version} from Github: #{res.message} #{res.statusCode}") if cb?
                    return
                    
                ws = req.pipe(fs.createWriteStream(@tarPath))
                ws.on 'finish', () =>
                    console.log("Fetched tarball from github: #{@tarFile}")
                    fs.mkdir @appPath, (err) =>
                        if err?
                            console.log(err)
                            cb(err) if cb?
                            return
                        console.log("Created #{@appPath}")
                        pushStatus 'Untarring' if pushStatus?
                        exec "tar --strip-components=1 -xf #{@tarFile} -C #{@appVersion}", { cwd: @tempPath, timeout: 300000 }, (err, stdout, stderr) =>
                            if err?
                                console.log("Error untarring files")
                            else
                                console.log("Untarred files from #{@tarPath}")
                            cb(err) if cb?
                ws.on 'error', (err) =>
                    console.log("Error downloading #{@appName}")
                    console.log(err)
                    cb(err) if cb?

            req.on 'error', (err) =>
                cb(err) if cb?
                return



    _runNpmInstall: (cb) ->
        console.log("npm installing in #{@appPath}")
        exec "npm install --production --cache=/tmp/#{@appName}", { cwd: @appPath }, (err, stdout, stderr) =>
            if err?
                cb(err) if cb?
                return
            console.log("npm installed in #{@appPath}")
            cb() if cb

    _retar: (cb) ->
        exec "tar -pczf #{@tarFile} #{@appVersion}/", { cwd: @tempPath, env: { GZIP: '-9' }}, (err, stdout, stderr) =>
            if err?
                cb(err) if cb?
                return
            console.log("re-tarred files in #{@appPath}")
            cb() if cb

    pushReleaseToS3: (force, pushStatus, cb) ->
        unless cb?
            unless pushStatus?
                cb = force
                force = false
                pushStatus = null
            else
                cb = pushStatus
                pushStatus = null
        pushStatus 'Checking whether it exists on S3' if pushStatus?
        @_existsOnS3 (exists) =>
            if exists and !force
                console.log("#{@appVersion} already present on S3")
                cb() if cb?
                return
            pushStatus 'Downloading from Github' if pushStatus?
            @_downloadFromGithub pushStatus, (err) =>
                if err?
                    console.log(err)
                    @_cleanUp ->
                        cb(err) if cb?
                    return
                pushStatus 'Running npm install' if pushStatus?
                @_runNpmInstall (err) =>
                    if err?
                        @_cleanUp ->
                            cb(err) if cb?
                        return
                    pushStatus 'Retarring' if pushStatus?
                    @_retar (err) => 
                        if err?
                            @_cleanUp ->
                                cb(err) if cb?
                            return
                        pushStatus 'Sending to S3' if pushStatus?
                        @_sendToS3 (err) =>
                            if err?
                                @_cleanUp ->
                                    cb(err) if cb?
                                return
                            @_cleanUp cb

if !module.parent
    appName = process.argv[2]
    version = process.argv[3]
    force = process.argv[4] ? false
    dl = new GitHubToS3(appName, version)
    dl.pushReleaseToS3(force, () ->)
