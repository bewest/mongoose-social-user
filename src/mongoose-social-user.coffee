SocialReq = require('social-request')
async = require('async')

module.exports = (schema, options) ->
  throw new Error('No mongoose instance supplied, set options.mongoose in plugin definition') unless options?.mongoose?
  mongoose = options.mongoose
  SocialUserDataSchema = new mongoose.Schema
    _user: 
      type: mongoose.Schema.Types.ObjectId
      ref: options.userModel or 'User'
    facebook: 
      userData: {}
      contacts: Array
    twitter:
      userData: {}
      contacts: Array
    google:
      userData: {}
      contacts: Array
    googleplus:
      userData: {}
      contacts: Array
  if mongoose.models.SocialUserData
    SocialUserData = mongoose.models.SocialUserData
  else
    SocialUserData = mongoose.model('SocialUserData', SocialUserDataSchema)

  socialReq = new SocialReq()
  socialReq
    .use('google', {clientId: options.google.clientId, clientSecret: options.google.clientSecret})
    .use('googleplus', {clientId: options.google.clientId, clientSecret: options.google.clientSecret})
    .use('facebook', {appId: options.facebook.appId, appSecret: options.facebook.appSecret})
  schema.add
    auth:
      facebook:
        id: String
        username: String
        aT: String
        createdAt: Date
      twitter:
        id: String
        username: String
        aT: String
        aTS: String
        createdAt: Date
      google:
        id: String
        username: String
        aT: String
        rT: String
        createdAt: Date
      googleplus:
        id: String
        username: String
        aT: String
        rT: String
        createdAt: Date
  _findOrCreateUser = (params, done) ->
    return done(new Error("couldn't log you in"))  if not params.service or not params.session or not params.data
    self = @
    upsertSocialIdToDatabase = (user, newUser, done) ->
      user.auth[params.service].id = params.data.id
      user.auth[params.service].username = params.data.username
      user.auth[params.service].createdAt = new Date() if newUser
      user.auth[params.service].aT = params.data.aT
      user.auth[params.service].rT = params.data.rT if params.data.rT?
      user.auth[params.service].aTS = params.data.aTS
      async.waterfall [
        (cb) ->
          SocialUserData.findOne {_user: user._id}, cb
      ,
        (socialUserData, cb) ->
          if not socialUserData?
            socialUserData = new SocialUserData
              _user: user._id
            socialUserData.save cb
          else
            cb null, socialUserData
      ], (err, socialUserData) ->
        return done err if err
        if not socialUserData[params.service]?.userData?
          socialUserData[params.service].userData = params.data
        else 
          for param of params.data
            socialUserData[params.service].userData[param] = params.data[param]
          socialUserData.markModified(params.service + '.userData')
        async.parallel
          user: (cb) ->
            user.save cb
          socialUserData: (cb) ->
            socialUserData.save cb
        , (err, results) ->
          done err, user, newUser
    userParams = {}
    userParams['auth.' + params.service + '.id'] = params.data.id
    if params.session?.auth?.userId?
      @findById params.session.auth.userId, (err, user) ->
        return done(err, null) if err
        return done(null) if not user?
        self.findOne userParams, (err, occupyingUser) ->
          return done(err ? new Error('Another user has already linked this account'))  if err? or (occupyingUser and occupyingUser.id isnt params.session.auth.userId)
          upsertSocialIdToDatabase user, false, done
    else
      upsertNewUser = () ->
        self.create {}, (err, user) ->
          upsertSocialIdToDatabase user, true, done
      @findOne userParams, (err, user) ->
        return done(err, null)  if err
        return upsertSocialIdToDatabase user, false, done if user?
        self.findOne
          'email': params.data.email
        , (err, user) ->
          return done err if err
          return upsertSocialIdToDatabase user, false, done if user?
          return upsertNewUser()
  schema.statics.findOrCreateUser = (service) ->
    self = @
    switch service
      when 'googlehybrid' then return (session, userAttributes) ->
        promise = @Promise()
        params =
          service: "google"
          session: session
          data: userAttributes
        params.data.id = params.data.claimedIdentifier.split('=')[1]
        params.data.username = params.data.email
        params.data.userData = {
          email: params.data.email,
          firstname: params.data.firstname,
          lastname: params.data.lastname
        }
        params.data.aT = params.data.access_token
        params.data.aTS = params.data.access_token_secret
        _findOrCreateUser.bind(self) params, (err, user, newUser) ->
          return promise.fulfill [err] if err
          session.newUser = newUser
          session.authUserData = params.data
          session.authUserData.service = params.service
          promise.fulfill user
        promise
      when 'google' then return (session, accessToken, accessTokExtra, userAttributes) ->
        promise = @Promise()
        params =
          service: "google"
          session: session
          data: userAttributes
        params.data.username = params.data.email
        params.data.aT = accessToken
        params.data.rT = accessTokExtra.refresh_token if accessTokExtra.refresh_token?
        params.data.aTE = accessTokExtra
        _findOrCreateUser.bind(self) params, (err, user, newUser) ->
          return promise.fulfill [err] if err
          session.newUser = newUser
          session.authUserData = params.data
          session.authUserData.service = params.service
          promise.fulfill user
        promise
      when 'facebook' then return (session, accessToken, accessTokExtra, fbUserMetaData) ->
        promise = @Promise()
        params =
          service: "facebook"
          session: session
          data: fbUserMetaData
        params.data.aT = accessToken
        params.data.aTE = accessTokExtra
        _findOrCreateUser.bind(self) params, (err, user, newUser) ->
          return promise.fulfill [err] if err
          session.newUser = newUser
          session.authUserData = params.data
          session.authUserData.service = params.service
          promise.fulfill user
        promise

  schema.methods._socialReqGet = (params, cb) ->
    self = @
    socialReq.getTokens (id, cb) ->
      cb
        facebook:
          access_token: self.auth.facebook.aT
        google: 
          access_token: self.auth.google.aT
          refresh_token: self.auth.google.rT
        googleplus: 
          access_token: self.auth.google.aT
    socialReq.get @.id, params, cb

  schema.methods.getSocial = (params, done) ->
    self = @
    self._socialReqGet params, (err, results) ->
      return done err if err
      processingFunctions = []
      secondTry = false
      secondTryParams = {}
      secondTryServices = []
      for requestType of results
        for service of results[requestType]
          if results[requestType][service].error?
            secondTry = true
            secondTryParams[requestType] = [] unless secondTryParams[requestType]?
            secondTryParams[requestType].push service 
            secondTryServices.push service if secondTryServices.indexOf(service) is -1
      removeServiceFromSecondTryParams = (service) ->
        for requestType of secondTryParams
          i = secondTryParams[requestType].indexOf service
          secondTryParams[requestType].splice i,1 if i isnt -1
          delete secondTryParams[requestType] if Object.keys(secondTryParams[requestType]).length is 0
      setErrorsForService = (service, err) ->
        for requestType of results
          for resultService of results[requestType] 
            if resultService is service
              results[requestType][service].error = err
      async.waterfall [
        (cb) ->
          return cb() if not secondTry
          async.forEach secondTryServices, (service, cb) ->
            if service is 'google'
              self._refreshAccessToken service, (err, user) ->
                if err
                  removeServiceFromSecondTryParams service
                  setErrorsForService service, err
                cb()
            else if service is 'googleplus'
              self._refreshAccessToken 'google', (err, user) ->
                if err
                  removeServiceFromSecondTryParams service
                  setErrorsForService service, err
                cb()
            else if service is 'facebook'
              removeServiceFromSecondTryParams service
              cb()
            else
              removeServiceFromSecondTryParams service
              cb()
          , (err) ->
            return cb(err) if err
            return cb() if Object.keys(secondTryParams).length is 0
            self._socialReqGet secondTryParams, (err, secondResults) ->
              return cb(err) if err
              for requestType of secondResults
                for service of secondResults[requestType]
                  results[requestType][service] = secondResults[requestType][service]
              cb()
      ], (err) ->
        return done err if err
        async.waterfall [
          (cb) ->
            SocialUserData.findOne {_user: self._id}, cb
        ,
          (socialUserData, cb) ->
            if not socialUserData?
              socialUserData = new SocialUserData
                _user: self._id
              socialUserData.save cb
            else
              cb null, socialUserData
        ], (err, socialUserData) ->
          return done err if err
          for requestType of results
            switch requestType
              when 'contacts'
                for service of results.contacts
                  unless results.contacts[service].error?
                    processingFunctions.push (cb) ->
                      async.filter results.contacts[service], (contact, cb) ->
                        switch service
                          when 'google'
                            cb contact.email?
                          else
                            cb true
                      , (contacts) ->
                        async.sortBy contacts, (contact, cb) ->
                          cb null, contact.entry.gd$name?.gd$familyName
                        , (err, contacts) ->
                          done err  if err
                          socialUserData[service] = {} unless socialUserData[service]
                          socialUserData[service].contacts = results.contacts[service] = contacts
                          cb()
              when 'details'
                for service of results.details
                  unless results.details[service].error?
                    if not socialUserData[service].userData?
                      socialUserData[service].userData = results.details[service]
                    else 
                      for param of results.details[service]
                        socialUserData[service].userData[param] = results.details[service][param]
                      socialUserData.markModified(service + '.userData')
          async.parallel processingFunctions, (err, processingResults) ->
            return done err  if err
            async.parallel
              user: (cb) ->
                self.save cb
              socialUserData: (cb) ->
                socialUserData.save cb
            , (err, models) ->
              done err, results

  ###
  schema.on 'init', (model) ->
    socialReq.getTokens (id, cb) ->
      model.findById id, (err, user) ->
        return cb(err || new Error 'User does not exist') if err? or not user?
        cb
          facebook:
            access_token: user.auth.facebook.aT
          google: 
            access_token: user.auth.google.aT
            access_token_secret: user.auth.google.aTS###

  schema.methods._invalidateAccessToken = (service, done) ->
    return done null, @ if not @auth[service]?
    @auth[service].aT = undefined
    @auth[service].aTS = undefined
    @save done
  schema.methods._refreshAccessToken = (service, done) ->
    return done null, @ if not @auth[service]?
    return done(new Error('No refresh token for service ' + service + ', user needs to be redirected to authentication screen')) if not @auth[service].rT?
    self = @
    socialReq.getTokens (id, cb) ->
      cb
        facebook:
          access_token: self.auth.facebook.aT
        google: 
          access_token: self.auth.google.aT
          refresh_token: self.auth.google.rT
        googleplus: 
          access_token: self.auth.google.aT
    socialReq.get @.id, {tokens: [service]}, (err, results) ->
      done (err or new Error 'Token refresh failed for some reason') if err or not results.tokens[service]?.access_token?
      self.auth.google.aT = results.tokens[service].access_token
      self.save done
  

  return