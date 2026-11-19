// INSTALL-FIRST-RUN-SETTINGS-1: the write of the facade's app settings, one
// level below facade-appsettings.bicep, which reads the settings the site has
// now and passes them here. Read and write in one template is refused as a
// circular dependency; see facade-appsettings.bicep for the whole story.
//
// The merge: the settings the site has now, then the template's own, then the
// Application Insights connection string and the authentication string. Later
// wins, so a setting added by hand stays and a template setting wins, and no
// setting can turn the authentication string off (STORE-LOGS-TELEMETRY-1).
//
// The current settings and the connection string are @secure(), so a
// deployment's history does not show their values.

@description('The facade site that gets the settings.')
param siteName string

@secure()
@description('The settings the site has now.')
param currentAppSettings object

@description('The settings the template states.')
param settings object

@secure()
@description('The Application Insights connection string.')
param connectionString string

resource site 'Microsoft.Web/sites@2025-03-01' existing = {
  name: siteName
}

resource appSettings 'Microsoft.Web/sites/config@2025-03-01' = {
  parent: site
  name: 'appsettings'
  properties: union(currentAppSettings, settings, {
    APPLICATIONINSIGHTS_CONNECTION_STRING: connectionString
    APPLICATIONINSIGHTS_AUTHENTICATION_STRING: 'Authorization=AAD'
  })
}