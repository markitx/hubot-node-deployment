AWS = require('aws-sdk')
jsonlint = require("jsonlint")
fs = require('fs')
path = require('path')
expect = require('expect.js')

AWS.config.update { region: 'us-east-1' }

cf = new AWS.CloudFormation

describe 'infrastructure', () ->
    describe 'templates', () ->
        describe 'valid JSON', () ->
            it 'should validate api_server.template', (done) ->
                contents = fs.readFileSync("#{__dirname}/../templates/api_server.template").toString()
                expect((() -> jsonlint.parse(contents))).to.not.throwError()
                done()

            it 'should validate elastic_search.template', (done) ->
                contents = fs.readFileSync("#{__dirname}/../templates/elastic_search.template").toString()
                expect((() -> jsonlint.parse(contents))).to.not.throwError()
                done()

            it 'should validate hubot.template', (done) ->
                contents = fs.readFileSync("#{__dirname}/../templates/hubot.template").toString()
                expect((() -> jsonlint.parse(contents))).to.not.throwError()
                done()

            it 'should validate load_balancers.template', (done) ->
                contents = fs.readFileSync("#{__dirname}/../templates/load_balancers.template").toString()
                expect((() -> jsonlint.parse(contents))).to.not.throwError()
                done()

            it 'should validate marvel.template', (done) ->
                contents = fs.readFileSync("#{__dirname}/../templates/marvel.template").toString()
                expect((() -> jsonlint.parse(contents))).to.not.throwError()
                done()

            it 'should validate public_api_server.template', (done) ->
                contents = fs.readFileSync("#{__dirname}/../templates/public_api_server.template").toString()
                expect((() -> jsonlint.parse(contents))).to.not.throwError()
                done()

            it 'should validate vpc.template', (done) ->
                contents = fs.readFileSync("#{__dirname}/../templates/vpc.template").toString()
                expect((() -> jsonlint.parse(contents))).to.not.throwError()
                done()

            it 'should validate webapp.template', (done) ->
                contents = fs.readFileSync("#{__dirname}/../templates/webapp.template").toString()
                expect((() -> jsonlint.parse(contents))).to.not.throwError()
                done()

            it 'should validate worker_node.template', (done) ->
                contents = fs.readFileSync("#{__dirname}/../templates/worker_node.template").toString()
                expect((() -> jsonlint.parse(contents))).to.not.throwError()
                done()

        describe 'valid CloudFormation template', (done) ->
            if AWS.config.credentials.accessKeyId?
                it 'should validate api_server.template', (done) ->
                    contents = fs.readFileSync("#{__dirname}/../templates/api_server.template").toString()
                    cf.validateTemplate TemplateBody: contents, done

                it 'should validate elastic_search.template', (done) ->
                    contents = fs.readFileSync("#{__dirname}/../templates/elastic_search.template").toString()
                    cf.validateTemplate TemplateBody: contents, done

                it 'should validate hubot.template', (done) ->
                    contents = fs.readFileSync("#{__dirname}/../templates/hubot.template").toString()
                    cf.validateTemplate TemplateBody: contents, done

                it 'should validate load_balancers.template', (done) ->
                    contents = fs.readFileSync("#{__dirname}/../templates/load_balancers.template").toString()
                    cf.validateTemplate TemplateBody: contents, done

                it 'should validate marvel.template', (done) ->
                    contents = fs.readFileSync("#{__dirname}/../templates/marvel.template").toString()
                    cf.validateTemplate TemplateBody: contents, done

                it 'should validate public_api_server.template', (done) ->
                    contents = fs.readFileSync("#{__dirname}/../templates/public_api_server.template").toString()
                    cf.validateTemplate TemplateBody: contents, done

                it 'should validate vpc.template', (done) ->
                    contents = fs.readFileSync("#{__dirname}/../templates/vpc.template").toString()
                    cf.validateTemplate TemplateBody: contents, done

                it 'should validate webapp.template', (done) ->
                    contents = fs.readFileSync("#{__dirname}/../templates/webapp.template").toString()
                    cf.validateTemplate TemplateBody: contents, done

                it 'should validate worker_node.template', (done) ->
                    contents = fs.readFileSync("#{__dirname}/../templates/worker_node.template").toString()
                    cf.validateTemplate TemplateBody: contents, done

