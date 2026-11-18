# S3-3: the VMF engine container. One job execution = one factory operation
# (assess | plan | wave); the wave orchestrator's worker processes run inside
# this container. Auth is the job's user-assigned managed identity - no
# credentials in the image, ever.
# Build cloud-side (no local Docker needed):
#   az acr build -r vmfacr<suffix> -t vmf-engine:dev -f docker/Dockerfile .
FROM mcr.microsoft.com/azure-powershell:16.5.0-ubuntu-24.04

# Layout mirrors the repo so module-relative guest-script resolution works.
COPY src/VmMigrationFactory /app/src/VmMigrationFactory
COPY src/guest              /app/src/guest
COPY docker/entrypoint.ps1  /app/entrypoint.ps1

WORKDIR /app
ENTRYPOINT ["pwsh", "-NoProfile", "-File", "/app/entrypoint.ps1"]
