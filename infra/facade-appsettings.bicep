// DEPS-CURRENT-1 part 4: the facade's app settings.
//
// The Azure Verified Module for a site (avm/res/web/site) wrote these until
// version 0.19.0. From 0.20.0 it also writes
// ApplicationInsightsAgent_EXTENSION_VERSION (~2 on a Windows app) whenever
// the settings name an Application Insights component, and that turns on the
// App Service Application Insights site extension. The facade never had it,
// and Microsoft's Functions app settings reference does not ask for it. A
// template can state an app setting and cannot unstate one, so once written
// it would stay on every install (tools/Deploy-VmfFacade.ps1 shows what
// removing a retired setting costs).
//
// So this module does exactly what the site module's config did at 0.19.0:
// the settings the site has now, then the template's own, then the component's
// connection string, read here in the deployment and never passed in. Nothing
// else is added. tests/unit/PlatformModules.Tests.ps1 holds it to that.
//
// INSTALL-FIRST-RUN-SETTINGS-1: the settings the site has now are read HERE,
// from the existing site, and handed to facade-appsettings-write.bicep, which
// writes them. platform.bicep read them with list() on the site's resourceId()
// and passed the result as a parameter. ARM read that before the facade module
// had made the site, in spite of the dependsOn: a first install into a new
// resource group stopped with ResourceNotFound on <site>/appsettings
// (2026-11-13). What was seen fits ARM reading a nested deployment's
// parameters when the template that holds it starts; that is not from a
// Microsoft page. This template starts only after the site module (the
// platform's dependsOn), so the read here finds the site.
// The write is one level further down because a read of
// <site>/config/appsettings in the template that also writes that resource
// is refused before anything runs: "Circular dependency detected on resource
// .../config/appsettings" (measured on the first try, 2026-11-13). The same
// shape as avm/res/web/site, which reads in one template and writes in a
// nested one.
// tests/unit/InstallFirstRunSettings.Tests.ps1 holds it to that.
//
// STORE-LOGS-TELEMETRY-1 adds one setting next to the connection string:
// APPLICATIONINSIGHTS_AUTHENTICATION_STRING = Authorization=AAD, the
// system-assigned form (no ClientId). The facade then signs its telemetry with
// its managed identity, which the run store's perimeter admits, and the
// component takes no key (disableLocalAuth in platform.bicep). It is written
// last, so no caller setting can turn it off.

@description('The facade site that gets the settings.')
param siteName string

@description('The Application Insights component whose connection string the facade sends its telemetry with.')
param appInsightsName string

@description('The settings the template states.')
param settings object

resource site 'Microsoft.Web/sites@2025-03-01' existing = {
  name: siteName
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: appInsightsName
}

// The settings the site has now, read as the site module read them at 0.19.0.
// Kept, so a setting written outside the template stays.
module write 'facade-appsettings-write.bicep' = {
  name: 'vmf-facade-appsettings-write'
  params: {
    siteName: siteName
    currentAppSettings: list('${site.id}/config/appsettings', '2023-12-01').properties
    settings: settings
    connectionString: appInsights.properties.ConnectionString
  }
}