# PUBLISH-IN-1: the service's code package, and the one job that puts it in the
# store.
#
# The package used to go from the laptop straight to blob storage. That is the
# one step of an install that a locked-down store refuses: a corporate policy
# forces publicNetworkAccess to Disabled, and the perimeter rule that admits
# every part of this product admits resources IN THE SUBSCRIPTION - never a
# laptop. So the upload moved inside Azure, and this is what runs there.
#
# It is its OWN image, not a passenger in the engine's: a zip of this code
# inside the existing image made no sense for a one-time job. The engine image runs for
# hours on customer estates; this one runs for about fifteen seconds, once per
# publish, and then nothing. Two lifetimes, two images.
#
# Build cloud-side (no local Docker needed):
#   az acr build -r vmfacr<suffix> -t vmf-publish:<tag> -f docker/publish/Dockerfile .
#
# The SAME base image as the engine, pinned to the same version, so this
# product trusts one base rather than two.
FROM mcr.microsoft.com/azure-powershell:16.5.0-ubuntu-24.04

# The package layout the Functions host expects, built here rather than on
# somebody's machine: the app at the root, and the two modules under Modules/
# where the host adds them to the module path. This mirrors what
# tools/Deploy-VmfFacade.ps1 used to stage locally - if you change one, change
# the other, and FacadeDeploy.Tests.ps1 fails if the two lists ever disagree.
COPY src/facade/app              /stage/
COPY src/VmMigrationFactory      /stage/Modules/VmMigrationFactory
COPY src/facade/FacadeCore       /stage/Modules/FacadeCore
COPY docker/publish/entrypoint.ps1 /app/entrypoint.ps1

# Zipped at BUILD time, not at run time. The image is then the package: what
# ran through the tests is byte for byte what reaches the store, and the job
# has nothing to do but the upload it exists for.
RUN pwsh -NoProfile -Command "Compress-Archive -Path /stage/* -DestinationPath /app/facade.zip" && \
    rm -rf /stage

WORKDIR /app
ENTRYPOINT ["pwsh", "-NoProfile", "-File", "/app/entrypoint.ps1"]
