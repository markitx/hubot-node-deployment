hubot-node-deployment
==============

An opinionated example of how to deploy a Node.js web stack (web front end + ngninx, public facing API server, internal API server, and elastic search) to AWS VPC using CloudFormation and not much else

## Config

## Commands
- `hubot deploy <application>[version] to <environment>` - Deploys the specified application with an optionally specified version to the specified environment
- `hubot deploy-multiple [<application> <version>, <application> <version>, ...] to <environment>` - Deploys the specified applications with the specified versions to the specified environment
- `hubot cancel <application>[version] to <environment>` - Cancel a deploy (Does not work with deploy-multiple)
- `hubot clean-up <application>[version] in <environment>` - Terminates all other versions of application in environment. Use after making sure your deploy looks good. Will be called automatically after 4 hours
- `hubot cleanup <application>[version] in <environment>` - Terminates all other versions of application in environment. Use after making sure your deploy looks good. Will be called automatically after 4 hours
- `hubot preserve <application> in <environment>` - Prevents automatic cleanup of this application.
- `hubot status <application> <version> in <environment>` - Get the latest status for a deploy
- `hubot history <application> <version> in <environment>` - Get the status history of a deploy
- `hubot rollback <application> in <environment>` - Rolls back to the previous version of the application
- `hubot version <application> [in <environment>]` - Prints out the currently deployed version of application. environment defaults to production
- `hubot add-dev-ip <ipaddress> [persist]` - Authorize access to development network for 24 hours, optionally persisting for an indefinite period of time
- `hubot add dev ip <ipaddress> [persist]` - Authorize access to development network for 24 hours, optionally persisting for an indefinite period of time
- `hubot remove-dev-ip <ipaddress>` - Deauthorize access to development network
- `hubot remove dev ip <ipaddress>` - Deauthorize access to development network
- `hubot bastion info [environment]` - Gets the info for the bastion host(s) used to ssh to actual instances.  If no environment is specified production is assumed
- `hubot bastion start [environment]` - Starts any bastion hosts that are not currently running.  If no environment is specified production is assumed
- `hubot bastion stop [environment]` - Stops any bastion hosts that are not currently running.  If no environment is specified production is assumed


## Notes

Be sure to replace the following variables in the templates prior to creating stacks with them in Cloud Formation:

- DEPLOYMENT-BUCKET: The S3 bucket where code will be copied by the deployment system
- ACCOUNT-ID: Your AWS account ID
- SSL-CERT-NAME: The name of the SSL certificate to use for the load balancers. You can choose a different one for each ELB

The following variables need to be set before running:

- HUBOT_DEPLOYMENT_AWS_KEY_NAME: ssl key used to secure instances
- HUBOT_DEPLOYMENT_BUCKET: the S3 bucket used to store deployment tarballs after downloading from Github and npm installing
- HUBOT_DEPLOYMENT_GITHUB_TOKEN: the Github API token used to download source code
- HUBOT_DEPLOYMENT_GITHUB_ORGANIZATION: the organization/user that the code lives in

A few other tidbits:

- The logging in the templates is set up for [LogEntries](www.logentries.com). You just need to get the [LogEntries data certificate](https://logentries.com/doc/certificates/) on the box and add the following code:
```json
  "$DefaultNetstreamDriverCAFile /path/to/logentries/certificate/syslog.logentries.crt\n",
  "$ActionSendStreamDriver gtls\n",
  "$ActionSendStreamDriverMode 1\n",
  "$ActionSendStreamDriverAuthMode x509/name\n",
  "$ActionSendStreamDriverPermittedPeer *.logentries.com\n",

  { "Fn::Join" : ["", ["$template LogentriesFormat,\"YOUR_LOG_ENTRIES_KEY ", { "Ref" : "Environment" }, " ", { "Ref" : "AppVersion" }, " ", " %HOSTNAME% %syslogtag%%msg%\\n\"\n"]] },

  "*.* @@api.logentries.com:20000;LogentriesFormat\n",
```
Be sure to replace /path/to/logentries/certificate, YOUR_LOG_ENTRIES_KEY, and AppVersion (with ApiServerVersion, PublicApiServerVersion, WebappVersion, or " email-processing-", { "Ref" : "EmailProcessingVersion" }, " file-import-", { "Ref" : "FileImportVersion" })

- Several IAM roles are assumed: api-server, public-api-server, webapp, elasticsearch-cluster, worker-node. Ensure these are created prior to creating stacks using the templates. The hubot role needs read/write access to the HUBOT_DEPLOYMENT_BUCKET as well as access to SQS And SNS. All other roles only need read access to HUBOT_DEPLOYMENT_BUCKET for initial deployment. If the apps use other AWS services their IAM role will need those permissions as well

- Support for notifying [Rollbar](https://www.rollbar.com) is in place. You just need to set the access tokens for projects in lib/deployment.coffee

- Deploys will automatically clean themselves up after 4 hours unless persisted

- Deploys should be done from the same platform that will be running the code. Since `npm install` will build native dependencies, if present, the packaging steps needs to be run on the same platform as deploys

- This example has a production and QA environment for webapp. This allows front end deploys to test against production data

- Access to Elastic Search and Marvel via outside the VPC is completely locked down in this example

- Hubot will ask users to set a personal Github token to ensure Rollbar reports exactly who deployed

- Be sure to copy the templates to DEPLOYMENT-BUCKET/templates/current

- You will need to hand create the hubot CloudFormation stack - and then can use that to deploy the other pieces

- The first time deploying the apps on worker-node you'll need to use `deploy-multiple` to deploy both at once. After that you can deploy new versions of just one app and hubot will use the old version of the other app

- The IP leasing functionality requires a DynamoDB table, development-ip-leases 

## Author
[dylanlingelbach](https://github.com/dylanlingelbach/)
