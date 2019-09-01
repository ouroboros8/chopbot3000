jwt = require 'jsonwebtoken'
{WebClient} = require "@slack/client"

appId = process.env.HUBOT_GITHUB_APP_ID
privateKey = process.env.HUBOT_GITHUB_APP_PRIVATE_KEY
maintainer_id = process.env.HUBOT_SLACK_MAINTAINER_ID
repository = process.env.HUBOT_GITHUB_REPOSITORY
installId = process.env.HUBOT_GITHUB_APP_INSTALL_ID

capitalize = (string) ->
  string.charAt(0).toUpperCase() + string.slice(1)

handleError = (robot, res, action, err, errMsg) ->
  friendlyMessage = "#{errMsg} while #{action}"
  logMessage = capitalize(friendlyMessage).concat(":\n#{err}")
  slackMessage = """
    :boom: sorry <@#{res.envelope.user.id}>, #{friendlyMessage}.
    Please report this to <@#{maintainer_id}>.
  """
  robot.logger.error(logMessage)
  res.send(slackMessage)

attributeTo = (user, body) ->
  attribution = "\n\n*-- reported on slack by #{user}.*"
  body.concat("\n\n", attribution)

newIssue = (res) ->
  lines = res.match[1].split('\n')
  title = lines.shift()
  body = attributeTo(res.envelope.user.real_name, lines.join('\n').trim())
  JSON.stringify({
    title: title,
    body: body
  })

new_jwt = ->
  now = Math.floor(Date.now() / 1000)
  claims = {iat: now, exp: now + 30, iss: appId}
  jwt.sign(claims, privateKey, { algorithm: 'RS256' })

addToWatchlist = (robot, thread_ts, comments_url) ->
  watchList = getWatchList(robot)
  watchList[thread_ts] = comments_url
  robot.brain.set('watchList', watchList)

getWatchList = (robot) ->
  robot.brain.get('watchList') or {}

with_access_token = (robot, res, callback) ->
  accessToken = robot.brain.get('accessToken')
  if accessToken? and (new Date(accessToken.expires_at) > new Date)
    robot.logger.info("Reusing access token with expiry #{accessToken.expires_at}")
    callback(accessToken.token)
  else
    robot.logger.info("Generating a new access token")
    app_token = new_jwt()
    robot.http("https://api.github.com/app/installations/#{installId}/access_tokens")
      .header('Accept', 'application/vnd.github.machine-man-preview+json')
      .header('Authorization', "Bearer #{app_token}")
      .post() (err, response, body) ->
        action = "attempting to generate an access token"
        if err
          handleError(robot, res, action, err, "an HTTP error occurred")
        else if response.statusCode isnt 201
          handleError(robot, res, action, err, "an unexpected states code #{response.statusCode} was returned")
        else
          accessToken = JSON.parse(body)
          robot.logger.info("New access token expires in #{accessToken.expires_at}")
          robot.brain.set('accessToken', accessToken)
          callback(accessToken.token)

module.exports = (robot) ->
  web = new WebClient robot.adapter.options.token

  robot.hear /!bug ([\s\S]+)/i, (res) ->
    if not res.message.thread_ts?
      res.message.thread_ts = res.message.rawMessage.ts # thread all responses
      with_access_token robot, res, (accessToken) ->
        issue = newIssue(res)
        robot.logger.debug("Reporting issue: #{issue}")
        robot.http("https://api.github.com/repos/#{repository}/issues")
          .header('Authorization', "Bearer #{accessToken}")
          .post(issue) (err, response, body) ->
            action = "attempting to create the issue"
            if err?
              handleError(robot, res, action, err, "an HTTP error occurred")
            else if response.statusCode isnt 201
              handleError(robot, res, action, body, "an unexpected states code #{response.statusCode} was returned")
            else
              {html_url, comments_url} = JSON.parse(body)
              res.send(
                """
                Thanks <@#{res.envelope.user.id}>, I've raised your issue here: #{html_url}
                If you'd like to add anything please add additional comments below.
                """
              )
              addToWatchlist(robot, res.message.thread_ts, comments_url)

  robot.hear /.*/i, (res) ->
    thread = res.message.thread_ts
    if thread?
      comments_url = getWatchList(robot)[thread]
      if comments_url?
        robot.logger.info("Got a message relating to #{comments_url} in #{thread}")
        res.message.thread_ts = res.message.rawMessage.ts # thread all responses
        web.reactions.add
          name: "speech_balloon"
          channel: res.message.room
          timestamp: res.message.id
        with_access_token robot, res, (accessToken) ->
          comment = JSON.stringify({
            body: attributeTo(res.envelope.user.real_name, res.match[0])
          })
          robot.http(comments_url)
            .header('Authorization', "Bearer #{accessToken}")
            .post(comment) (err, response, body) ->
              if err?
                handleError(robot, res, action, err, "an HTTP error occurred")
              else if response.statusCode isnt 201
                handleError(robot, res, action, body, "an unexpected states code #{response.statusCode} was returned")
              else
                web.reactions.remove
                  name: "speech_balloon"
                  channel: res.message.room
                  timestamp: res.message.id
                web.reactions.add
                  name: "heavy_check_mark"
                  channel: res.message.room
                  timestamp: res.message.id
