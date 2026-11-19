# FAQ for Trusted Launch - Azure Virtual Machines | Microsoft Learn

Frequently asked questions (FAQs) about Azure Trusted Launch feature use cases, support for other Azure features, and fixes for common errors.

## Use cases

This section answers questions about use cases for Trusted Launch.

Trusted Launch is supported on both x64 and Arm64 Generation 2 Azure VMs, including [Cobalt 100](sizes/cobalt-overview)-based Arm64 sizes when using supported images.

### Why should I use Trusted Launch? What does Trusted Launch guard against?

Trusted Launch guards against boot kits, rootkits, and kernel-level malware. These sophisticated types of malware run in kernel mode and remain hidden from users. For example:

- **Firmware rootkits**: These kits overwrite the firmware of the virtual machine (VM) BIOS, so the rootkit can start before the operating system (OS).
- **Boot kits**: These kits replace the OS's bootloader so that the VM loads the boot kit before the OS.
- **Kernel rootkits**: These kits replace a portion of the OS kernel, so the rootkit can start automatically when the OS loads.
- **Driver rootkits**: These kits pretend to be one of the trusted drivers that the OS uses to communicate with the VM's components.

### What are the differences between Secure Boot and measured boot?

In a Secure Boot chain, each step in the boot process checks a cryptographic signature of the subsequent steps. For example, the BIOS checks a signature on the loader, and the loader checks signatures on all the kernel objects that it loads, and so on. If any of the objects are compromised, the signature doesn't match and the VM doesn't boot. For more information, see [Secure Boot](/en-us/windows-hardware/design/device-experiences/oem-secure-boot).

### How does Trusted Launch compare to Hyper-V Shielded VM?

Hyper-V Shielded VM is currently available on Hyper-V only. [Hyper-V Shielded VM](/en-us/windows-server/security/guarded-fabric-shielded-vm/guarded-fabric-and-shielded-vms) is typically deployed with Guarded Fabric. A Guarded Fabric consists of a Host Guardian Service (HGS), one or more guarded hosts, and a set of Shielded VMs. Hyper-V Shielded VMs are used in fabrics where the data and state of the VM must be protected from various actors. These actors are both fabric administrators and untrusted software that might be running on the Hyper-V hosts.

Trusted launch can be deployed as a standalone VM or as virtual machine scale sets on Azure without other deployment and management of HGS. All of the Trusted Launch features can be enabled with a simple change in deployment or a checkbox on the Azure portal.

### What is VM Guest State (VMGS)?

VM Guest State (VMGS) is specific to Trusted Launch VMs. It's a blob managed by Azure and contains the unified extensible firmware interface (UEFI) Secure Boot signature databases and other security information. The lifecycle of the VMGS blob is tied to that of the OS disk.

## Supported features and deployments

This section discusses Trusted Launch supported features and deployments.

### Are Arm64 VM sizes and images supported with Trusted Launch?

Yes, Trusted Launch is supported for Arm64 VMs. Arm64 images with Trusted Launch are available in Azure Marketplace. The [Cobalt 100-based Arm64 VM series](sizes/cobalt-overview) support Trusted Launch. You can deploy Trusted Launch on these Arm64 sizes using validated marketplace images.

### Is Azure Compute Gallery supported by Trusted Launch?

Trusted Launch now allows images to be created and shared through the [Azure Compute Gallery](trusted-launch-portal#trusted-launch-vm-supported-images) (formerly Shared Image Gallery). The image source can be:

- An existing Azure VM that is either generalized or specialized.
- An existing managed disk or a snapshot.
- A virtual hard disk (VHD) or an image version from another gallery.

For more information about deploying a Trusted Launch VM by using the Azure Compute Gallery, see [Deploy Trusted Launch VMs](trusted-launch-portal#deploy-a-trusted-launch-vm-from-an-azure-compute-gallery-image).

### Is Azure Backup supported by Trusted Launch?

Trusted Launch now supports Azure Backup. For more information, see [Support matrix for Azure VM backup](/en-us/azure/backup/backup-support-matrix-iaas#vm-compute-support).

### Will Azure Backup continue working after I enable Trusted Launch?

Backups configured with the [Enhanced policy](/en-us/azure/backup/backup-azure-vms-enhanced-policy) continue to take backups of VMs after you enable Trusted Launch.

### Are ephemeral OS disks supported by Trusted Launch?

Trusted Launch supports ephemeral OS disks. For more information, see [Trusted Launch for ephemeral OS disks](ephemeral-os-disks#trusted-launch-for-ephemeral-os-disks).

Note

For Trusted launch VMs created with ephemeral disks, Keys and secrets generated or sealed by the virtual Trusted Platform Module (vTPM) after the creation of the VM might not be persisted across operations like reimaging and platform events like service healing.

### Are security features available with Trusted launch applicable to data disks as well?

Trusted launch provides foundational security for Operating system hosted in virtual machine by attesting its boot integrity. Trusted launch security features are applicable for running OS and OS disks only, they aren't applicable to data disks or OS binaries stored in data disks. For more information, see [Trusted launch overview](trusted-launch)

### Can a VM be restored by using backups taken before Trusted Launch was enabled?

Backups taken before you [upgrade an existing Generation 2 VM to Trusted Launch](trusted-launch-existing-vm) can be used to restore the entire VM or individual data disks. They can't be used to restore or replace the OS disk only.

### How can I find VM sizes that support Trusted Launch?

See the list of [Generation 2 VM sizes that support Trusted Launch](trusted-launch#virtual-machines-sizes), which includes both x64 and Arm64 sizes.

Arm64 [Cobalt 100](sizes/cobalt-overview)-based VM sizes (Dpsv6, Dplsv6, Epsv6) support Trusted Launch. These Arm64 sizes are Gen2 and support Trusted Launch.

Use the following commands to check if a [Generation 2 VM size](generation-2#generation-2-vm-sizes) doesn't support Trusted Launch.

# [CLI](#tab/adhoccli)
```azurecli
subscription="<yourSubID>"
region="westus"
vmSize="Standard_NC12s_v3"

az vm list-skus --resource-type virtualMachines  --location $region --query "[?name=='$vmSize'].capabilities" --subscription $subscription
```

# [PowerShell](#tab/adhocPowerShell)
```azurepowershell
$region = "southeastasia"
$vmSize = "Standard_M64"
(Get-AzComputeResourceSku | where {$_.Locations.Contains($region) -and ($_.Name -eq $vmSize) })[0].Capabilities
```

The response is similar to the following form. Output that includes `TrustedLaunchDisabled True` indicates that the Generation 2 VM size doesn't support Trusted Launch. If it's a Generation 2 VM size and `TrustedLaunchDisabled` isn't part of the output, Trusted Launch is supported for that VM size. For Arm64 sizes, the `CpuArchitectureType` capability is `Arm64` and the absence of `TrustedLaunchDisabled` on a Gen2 Arm64 size indicates Trusted Launch support.

```
Name                                         Value
----                                         -----
MaxResourceVolumeMB                          8192000
OSVhdSizeMB                                  1047552
vCPUs                                        64
MemoryPreservingMaintenanceSupported         False
HyperVGenerations                            V1,V2
MemoryGB                                     1000
MaxDataDiskCount                             64
CpuArchitectureType                          x64
MaxWriteAcceleratorDisksAllowed              8
LowPriorityCapable                           True
PremiumIO                                    True
VMDeploymentTypes                            IaaS
vCPUsAvailable                               64
ACUs                                         160
vCPUsPerCore                                 2
CombinedTempDiskAndCachedIOPS                80000
CombinedTempDiskAndCachedReadBytesPerSecond  838860800
CombinedTempDiskAndCachedWriteBytesPerSecond 838860800
CachedDiskBytes                              1318554959872
UncachedDiskIOPS                             40000
UncachedDiskBytesPerSecond                   1048576000
EphemeralOSDiskSupported                     True
EncryptionAtHostSupported                    True
CapacityReservationSupported                 False
TrustedLaunchDisabled                        True
AcceleratedNetworkingEnabled                 True
RdmaEnabled                                  False
MaxNetworkInterfaces                         8
```

---

### How can I validate that my OS image supports Trusted Launch?

See the list of [OS versions supported with Trusted Launch](trusted-launch#operating-systems-supported).

Both x64 and Arm64 Gen2 images can support Trusted Launch. For Arm64 images, the CLI/PowerShell outputs show `architecture` as `Arm64` and the `features` include `SecurityType` with `TrustedLaunch` or `TrustedLaunchSupported`.

#### Marketplace OS images

Use the following commands to check if an Azure Marketplace OS image supports Trusted Launch.

# [CLI](#tab/adhoccli)
```azurecli
az vm image show --urn "MicrosoftWindowsServer:WindowsServer:2022-datacenter-azure-edition:latest"
```

The response is similar to the following form. If `hyperVGeneration` is `V2` and `SecurityType` contains `TrustedLaunch` in the output, the Generation 2 OS image supports Trusted Launch.

```json
{
  "architecture": "x64",
  "automaticOsUpgradeProperties": {
    "automaticOsUpgradeSupported": false
  },
  "dataDiskImages": [],
  "disallowed": {
    "vmDiskType": "Unmanaged"
  },
  "extendedLocation": null,
  "features": [
    {
      "name": "SecurityType",
      "value": "TrustedLaunchAndConfidentialVmSupported"
    },
    {
      "name": "IsAcceleratedNetworkSupported",
      "value": "True"
    },
    {
      "name": "DiskControllerTypes",
      "value": "SCSI, NVMe"
    },
    {
      "name": "IsHibernateSupported",
      "value": "True"
    }
  ],
  "hyperVGeneration": "V2",
  "id": "/Subscriptions/00000000-0000-0000-0000-00000000000/Providers/Microsoft.Compute/Locations/westus/Publishers/MicrosoftWindowsServer/ArtifactTypes/VMImage/Offers/WindowsServer/Skus/2022-datacenter-azure-edition/Versions/20348.1906.230803",
  "imageDeprecationStatus": {
    "alternativeOption": null,
    "imageState": "Active",
    "scheduledDeprecationTime": null
  },
  "location": "westus",
  "name": "20348.1906.230803",
  "osDiskImage": {
    "operatingSystem": "Windows",
    "sizeInGb": 127
  },
  "plan": null,
  "tags": null
}
```

For Arm64 Marketplace images (for example, `Canonical:0001-com-ubuntu-server-jammy:22_04-lts-arm64:latest`), the output shows `"architecture": "Arm64"` with `SecurityType` including `TrustedLaunchSupported`.

# [PowerShell](#tab/adhocPowerShell)
```azurepowershell
Get-AzVMImage -Skus 22_04-lts-gen2 -PublisherName Canonical -Offer 0001-com-ubuntu-server-jammy -Location westus3 -Version latest
```

You can use the output of the command with [Virtual machines - Get API](/en-us/rest/api/compute/virtual-machine-images/get). The response is similar to the following form. If `hyperVGeneration` is `V2` and `SecurityType` contains `TrustedLaunch` in the output, the Generation 2 OS image supports Trusted Launch.

```json
{
    "properties": {
        "hyperVGeneration": "V2",
        "architecture": "x64",
        "replicaType": "Managed",
        "replicaCount": 10,
        "disallowed": {
            "vmDiskType": "Unmanaged"
        },
        "automaticOSUpgradeProperties": {
            "automaticOSUpgradeSupported": false
        },
        "imageDeprecationStatus": {
            "imageState": "Active"
        },
        "features": [
            {
                "name": "SecurityType",
                "value": "TrustedLaunchSupported"
            },
            {
                "name": "IsAcceleratedNetworkSupported",
                "value": "True"
            },
            {
                "name": "DiskControllerTypes",
                "value": "SCSI, NVMe"
            },
            {
                "name": "IsHibernateSupported",
                "value": "True"
            }
        ],
        "osDiskImage": {
            "operatingSystem": "Linux",
            "sizeInGb": 30
        },
        "dataDiskImages": []
    },
    "location": "WestUS3",
    "name": "22.04.202309080",
    "id": "/Subscriptions/00000000-0000-0000-0000-000000000000/Providers/Microsoft.Compute/Locations/WestUS3/Publishers/Canonical/ArtifactTypes/VMImage/Offers/0001-com-ubuntu-server-jammy/Skus/22_04-lts-gen2/Versions/22.04.202309080"
}
```

---

#### Azure Compute Gallery OS image

Use the following commands to check if an [Azure Compute Gallery](trusted-launch-portal#trusted-launch-vm-supported-images) OS image supports Trusted Launch.

# [CLI](#tab/adhoccli)
```azurecli
az sig image-definition show `
    --gallery-image-definition myImageDefinition `
    --gallery-name myImageGallery `
    --resource-group myImageGalleryRg
```

The response is similar to the following form. If `hyperVGeneration` is `V2` and `SecurityType` contains `TrustedLaunch` in the output, the Generation 2 OS image supports Trusted Launch.

```json
{
  "architecture": "x64",
  "features": [
    {
      "name": "SecurityType",
      "value": "TrustedLaunchSupported"
    }
  ],
  "hyperVGeneration": "V2",
  "id": "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/myImageGalleryRg/providers/Microsoft.Compute/galleries/myImageGallery/images/myImageDefinition",
  "identifier": {
    "offer": "myImageDefinition",
    "publisher": "myImageDefinition",
    "sku": "myImageDefinition"
  },
  "location": "westus3",
  "name": "myImageDefinition",
  "osState": "Generalized",
  "osType": "Windows",
  "provisioningState": "Succeeded",
  "recommended": {
    "memory": {
      "max": 32,
      "min": 1
    },
    "vCPUs": {
      "max": 16,
      "min": 1
    }
  },
  "resourceGroup": "myImageGalleryRg",
  "tags": {},
  "type": "Microsoft.Compute/galleries/images"
}
```

# [PowerShell](#tab/adhocPowerShell)
```azurepowershell
Get-AzGalleryImageDefinition -ResourceGroupName myImageGalleryRg `
    -GalleryName myImageGallery -GalleryImageDefinitionName myImageDefinition
```

The response is similar to the following form. If `hyperVGeneration` is `V2` and `SecurityType` contains `TrustedLaunch` in the output, the Generation 2 OS image supports Trusted Launch.

```
ResourceGroupName : myImageGalleryRg
OsType            : Windows
OsState           : Generalized
HyperVGeneration  : V2
Identifier        :
  Publisher       : myImageDefinition
  Offer           : myImageDefinition
  Sku             : myImageDefinition
Recommended       :
  VCPUs           :
    Min           : 1
    Max           : 16
  Memory          :
    Min           : 1
    Max           : 32
ProvisioningState : Succeeded
Id                : /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/myImageGalleryRg/providers/Microsoft.Compute/galleries/myImageGallery/images/myImageDefinition
Name              : myImageDefinition
Type              : Microsoft.Compute/galleries/images
Location          : westus3
Tags              : {}
Features[0]       :
  Name            : SecurityType
  Value           : TrustedLaunchSupported
Architecture      : x64
```

---

### How can I validate Secure boot compatibility for Gen1 or Gen2 VM before upgrade to Trusted launch?

To self-evaluate the presence of untrusted boot components or kernel modules in your existing Gen1/Gen2 Linux VMs before migrating to Trusted Launch, you can use the `SBInfo` tool from the Linux Security Package

1. Connect to your Azure Linux Gen1/Gen2 VM.
2. Install the SBInfo tool for the distribution your VM is running. It resides within the Linux Security Package.

Refer to Linux Trusted launch Secure boot validation for distribution-based `SBInfo` tool installation commands.

### How do external communication drivers work with Trusted Launch VMs?

Adding component object model (COM) ports require that you disable Secure Boot. COM ports are disabled by default in Trusted Launch VMs.

## Trusted launch as default (TLaD)

### What is Trusted Launch as default?

Trusted launch as default (TLaD) is generally available. For more information, see [Trusted launch default (General Availability)](trusted-launch#general-availability-trusted-launch-as-default).

### Does TLaD impacts existing VM & scale sets?

Trusted launch as default doesn't change existing Azure VMs, scale sets already running in your environment

### Do I need to update my automation scripts or deployment templates?

You need to update the API versions for following resource providers to validate the Trusted launch default end to end experience as part of the preview:

- `Microsoft.Compute/virtualMachines` – API version `2021-11-01` or higher.
- `Microsoft.Compute/virtualMachineScaleSets` – API version `2021-11-01` or higher.

### I'm currently using Gen2 VM or scale set without Trusted Launch and would like to continue using Non-Trusted Launch configuration after the TLaD general availability

Trusted Launch VMs provide you with foundational compute security at no extra cost. We strongly recommend that you don't disable them for new VM or scale set deployments. Reach out to us at [Trusted launch default feedback](https://aka.ms/TrustedLaunchDefault/Feedback).

See [Can I disable Trusted launch for new deployment](trusted-launch-faq#can-i-disable-trusted-launch-for-a-new-vm-deployment) if you explicitly need to disable Trusted launch.

### What could be possible situations where I must bypass Trusted launch defaults for VM or scale set?

You need to explicitly bypass Trusted launch default if one of the following scenarios applies to your Gen2 VM or scale set deployments:

- Gen2 VM is used to generate `TrustedLaunchSupported` or `TrustedLaunchAndConfidentialVMSupported` or `ConfidentialVMSupported`[Azure compute gallery](azure-compute-gallery) images via [Azure image builder (AIB)](image-builder-overview) or Packer. OR,
- Gen2 VM is used to create [managed images*](capture-image-portal). OR,
- Gen2 Linux VM requires [Hibernation](hibernate-resume) enabled.

Note

For managed images, use [Azure Compute Gallery](azure-compute-gallery) for the latest capabilities. All new features, like ARM64, Trusted Launch, and Confidential VM are only supported through Azure Compute Gallery.

### Can I disable Trusted Launch for a new VM deployment?

Trusted Launch VMs provide you with foundational compute security. We **strongly** recommend that you don't disable them for new VM or scale set deployments except if your deployments have dependency on:

- [A VM size currently not supported](trusted-launch#virtual-machines-sizes)
- [Unsupported features with Trusted Launch](trusted-launch#unsupported-features)
- [An OS that doesn't support Trusted Launch](trusted-launch#operating-systems-supported)
- [VM used to generate TrustedLaunchSupported Azure compute gallery image](trusted-launch-portal#trusted-launch-vm-supported-images)

To disable Trusted Launch in new VM or scale set deployments, use the `securityType` parameter with the `Standard` value by using Microsoft.Compute API version 2025-11-01+, Azure PowerShell (v15.6.1+), and the Azure CLI (v2.86.0+).

Note

Don't disable Secure Boot unless you're using custom unsigned kernel or drivers.

If you need to disable Secure Boot, under the VM's configuration, clear the **Enable Secure Boot** option.

# [Template](#tab/template)
Sample `securityProfile` element of ARM template for using `securityType` parameter with value `Standard`

```json
"securityProfile": {
    "securityType": "Standard",
    "uefiSettings": "[null()]"
}
```

# [CLI](#tab/cli)
```azurecli
az vm create -n MyVm -g MyResourceGroup --image Ubuntu2204 `
    --security-type 'Standard'
```

# [PowerShell](#tab/PowerShell)
```azurepowershell
$adminUsername = <USER NAME>
$adminPassword = <PASSWORD> | ConvertTo-SecureString -AsPlainText -Force
$vmCred = New-Object System.Management.Automation.PSCredential($adminUsername, $adminPassword)
New-AzVM -Name MyVm -Credential $vmCred -SecurityType Standard
```

---

## Troubleshooting issues

This section answers questions about specific states, boot types, and common boot issues.

### What should I do when my Trusted Launch VM has deployment failures?

This section provides more details on Trusted Launch deployment failures for you to take proper action to prevent them.

```json
Virtual machine <vm name> failed to create from the selected snapshot because the virtual Trusted Platform Module (vTPM) state is locked.
To proceed with the VM creation, please select a different snapshot without a locked vTPM state.
For more assistance, please refer to “Troubleshooting locked vTPM state” in FAQ page at https://aka.ms/TrustedLaunch-FAQ. 
```

This deployment error happens when the snapshot or restore point provided is inaccessible or unusable for the following reasons:

1. Corrupt virtual machine guest state (VMGS).
2. vTPM in a locked state.
3. One or more critical vTPM indices are in an invalid state.

The listed reasons can happen if a user or workload running on the virtual machine sets the lock on vTPM or modifies critical vTPM indices that leave the vTPM in an invalid state.

Retrying with the same snapshot or restore point results in the same failure.

**Resolution:**

1. On the source Trusted Launch VM where the snapshot or restore point was generated, the vTPM errors must be rectified.
    1. For vTPM state modified by a workload on the virtual machine, you need to use the same to check the error states and bring the vTPM to a non-error state.
    2. For vTPM state modified using trusted platform module (TPM) tools, then you should use the same tools to check the error states and bring the vTPM to a non-error state.

Once the snapshot or restore point is free from these errors, you can use same to create a new Trusted Launch VM.

### Why is the Trusted Launch VM not booting correctly?

If unsigned components are detected from the UEFI (guest firmware), bootloader, OS, or boot drivers, a Trusted Launch VM doesn't boots. The [Secure Boot](/en-us/windows-server/virtualization/hyper-v/learn-more/generation-2-virtual-machine-security-settings-for-hyper-v#secure-boot-setting-in-hyper-v-manager) setting in the Trusted Launch VM fails to boot if unsigned or untrusted boot components are encountered during the boot process and reports as a Secure Boot failure.

![Screenshot that shows the Trusted Launch pipeline from Secure Boot to third-party drivers.](media/trusted-launch/trusted-launch-pipeline.png)

Note

Trusted Launch VMs that are created directly from an Azure Marketplace image shouldn't encounter Secure Boot failures. Azure Compute Gallery images with an original image source of Azure Marketplace and snapshots created from Trusted Launch VMs should also not encounter these errors.

### How would I verify a no-boot scenario in the Azure portal?

When a VM becomes unavailable from a Secure Boot failure, `no-boot` means that VM has an OS component not signed by a trusted authority, which blocks booting a Trusted Launch VM. On VM deployment, you might see information from resource health within the Azure portal stating that there's a validation error in Secure Boot.

To access resource health from the VM configuration page, go to **Resource Health** under the **Help** pane.

[![Screenshot that shows a resource health error message alerting a failed Secure Boot.](media/trusted-launch/resource-health-error.png)](media/trusted-launch/resource-health-error.png#lightbox)

If you verified that the no-boot is caused due to Secure Boot failure:

1. The image you're using is an older version that might have one or more untrusted boot components and is on a deprecation path. To remedy an outdated image, update to a supported newer image version.
2. The image you're using might be built outside of a marketplace source or the boot components modified and contain unsigned or untrusted boot components. To verify whether your image has unsigned or untrusted boot components, see the following section, "Verify Secure Boot failures."
3. If the preceding two scenarios don't apply, the VM is potentially infected with malware (bootkit/rootkit). Consider deleting the VM and re-creating a new VM from the same source image while you evaluate all the software being installed.

### Why does my Trusted Launch VM show 50 MB less memory?

With Trusted Launch, an execution environment commonly known as "the paravisor" is created and runs inside the VM. Typically, about 50MB of memory is used by the paravisor and would show as "reserved" within the guest Operating System.

## Verify Secure Boot failures

This section helps you verify Secure Boot failures.

### Linux Trusted launch virtual machines

To verify which boot components are responsible for Secure Boot failures within an Azure Linux Trusted Launch VM, you can use the `SBInfo` tool from the Linux Security Package

1. Turn off Secure Boot.
2. Connect to your Azure Linux Trusted Launch VM.
3. Install the SBInfo tool for the distribution your VM is running. It resides within the Linux Security Package

# [Debian-based distributions](#tab/debianbased)
These commands apply to Ubuntu, Debian, and other Debian-based distributions.

```bash
echo "deb [arch=amd64] http://packages.microsoft.com/repos/azurecore/ trusty main" | sudo tee -a /etc/apt/sources.list.d/azure.list

echo "deb [arch=amd64] http://packages.microsoft.com/repos/azurecore/ xenial main" | sudo tee -a /etc/apt/sources.list.d/azure.list

echo "deb [arch=amd64] http://packages.microsoft.com/repos/azurecore/ bionic main" | sudo tee -a /etc/apt/sources.list.d/azure.list

wget https://packages.microsoft.com/keys/microsoft.asc

wget https://packages.microsoft.com/keys/msopentech.asc

sudo apt-key add microsoft.asc && sudo apt-key add msopentech.asc

sudo apt update && sudo apt install azure-security

```

# [Red Hat-based distributions](#tab/rhelbased)
These commands apply to RHEL and other Red Hat-based distributions.

```bash
echo "[packages-microsoft-com-azurecore]" | sudo tee -a /etc/yum.repos.d/azurecore.repo

echo "name=packages-microsoft-com-azurecore" | sudo tee -a /etc/yum.repos.d/azurecore.repo

echo "baseurl=https://packages.microsoft.com/yumrepos/azurecore/" | sudo tee -a /etc/yum.repos.d/azurecore.repo

echo "enabled=1" | sudo tee -a /etc/yum.repos.d/azurecore.repo

echo "gpgcheck=0" | sudo tee -a /etc/yum.repos.d/azurecore.repo

sudo yum install azure-security
```

# [SUSE-based distributions](#tab/susebased)
These commands apply to SLES, openSUSE, and other SUSE-based distributions.

```bash
sudo zypper ar -t rpm-md -n "packages-microsoft-com-azurecore" --no-gpgcheck https://packages.microsoft.com/yumrepos/azurecore/ azurecore

sudo zypper install azure-security
```

---

After you install the Linux Security Package for your distribution, run the `sbinfo` command to verify which boot components are responsible for Secure Boot failures by displaying all unsigned modules, kernels, and bootloaders.

```bash
sudo sbinfo -u -m -k -b 
```

To learn more about the SBInfo diagnostic tool, you can run `sudo sbinfo -help`.

### Why am I getting a boot integrity monitoring fault?

Trusted Launch for Azure VMs is monitored for advanced threats. If such threats are detected, an alert is triggered. Alerts are only available if [enhanced security features in Microsoft Defender for Cloud](/en-us/azure/security-center/enable-enhanced-security) are enabled.

Microsoft Defender for Cloud periodically performs attestation. If the attestation fails, a medium-severity alert is triggered. Trusted Launch attestation can fail for the following reasons:

- The attested information, which includes a log of the Trusted Computing Base (TCB), deviates from a trusted baseline (like when Secure Boot is enabled). Any deviation indicates that untrusted modules were loaded and the OS might be compromised.
- The attestation quote couldn't be verified to originate from the vTPM of the attested VM. The verification failure indicates malware is present and might be intercepting traffic to the TPM.
- The attestation extension on the VM isn't responding. An unresponsive extension indicates a denial-of-service attack by malware or an OS admin.

## Certificates

This section provides information on certificates.

### How can I establish root of trust with Trusted Launch VMs?

The virtual TPM AK public certificate provides you with visibility for information on the full certificate chain (Root and Intermediate Certificates) to help you validate trust in the certificate and root chain. It provides information on instance properties so that you can trace back to the full chain. It ensures that you continually have the highest security posture for Trusted Launch

#### Download instructions

Package certificates, composed of .p7b (Full Certificate Authority) and .cer (Intermediate CA), reveal the signing and certificate authority. Copy the relevant content and use certificate tooling to inspect and assess details of certificates.

Select to download the .crt that follows for the Azure Virtual TPM Root Certificate Authority 2023

[Azure Virtual TPM Root Certificate Authority 2023](https://www.microsoft.com/pkiops/certs/Azure%20Virtual%20TPM%20Root%20Certificate%20Authority%202023.crt)

Select to view the .cert content for the Root Certificate

Azure Virtual TPM Root Certificate Authority 2023

```
-----BEGIN CERTIFICATE-----
MIIFsDCCA5igAwIBAgIQUfQx2iySCIpOKeDZKd5KpzANBgkqhkiG9w0BAQwFADBp
MQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMTow
OAYDVQQDEzFBenVyZSBWaXJ0dWFsIFRQTSBSb290IENlcnRpZmljYXRlIEF1dGhv
cml0eSAyMDIzMB4XDTIzMDYwMTE4MDg1M1oXDTQ4MDYwMTE4MTU0MVowaTELMAkG
A1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjE6MDgGA1UE
AxMxQXp1cmUgVmlydHVhbCBUUE0gUm9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkg
MjAyMzCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALoMMwvdRJ7+bW00
adKE1VemNqJS+268Ure8QcfZXVOsVO22+PL9WRoPnWo0r5dVoomYGbobh4HC72s9
sGY6BGRe+Ui2LMwuWnirBtOjaJ34r1ZieNMcVNJT/dXW5HN/HLlm/gSKlWzqCEx6
gFFAQTvyYl/5jYI4Oe05zJ7ojgjK/6ZHXpFysXnyUITJ9qgjn546IJh/G5OMC3mD
fFU7A/GAi+LYaOHSzXj69Lk1vCftNq9DcQHtB7otO0VxFkRLaULcfu/AYHM7FC/S
q6cJb9Au8K/IUhw/5lJSXZawLJwHpcEYzETm2blad0VHsACaLNucZL5wBi8GEusQ
9Wo8W1p1rUCMp89pufxa3Ar9sYZvWeJlvKggWcQVUlhvvIZEnT+fteEvwTdoajl5
qSvZbDPGCPjb91rSznoiLq8XqgQBBFjnEiTL+ViaZmyZPYUsBvBY3lKXB1l2hgga
hfBIag4j0wcgqlL82SL7pAdGjq0Fou6SKgHnkkrV5CNxUBBVMNCwUoj5mvEjd5mF
7XPgfM98qNABb2Aqtfl+VuCkU/G1XvFoTqS9AkwbLTGFMS9+jCEU2rw6wnKuGv1T
x9iuSdNvsXt8stx4fkVeJvnFpJeAIwBZVgKRSTa3w3099k0mW8qGiMnwCI5SfdZ2
SJyD4uEmszsnieE6wAWd1tLLg1jvAgMBAAGjVDBSMA4GA1UdDwEB/wQEAwIBhjAP
BgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBRL/iZalMH2M8ODSCbd8+WwZLKqlTAQ
BgkrBgEEAYI3FQEEAwIBADANBgkqhkiG9w0BAQwFAAOCAgEALgNAyg8I0ANNO/8I
2BhpTOsbywN2YSmShAmig5h4sCtaJSM1dRXwA+keY6PCXQEt/PRAQAiHNcOF5zbu
OU1Bw/Z5Z7k9okt04eu8CsS2Bpc+POg9js6lBtmigM5LWJCH1goMD0kJYpzkaCzx
1TdD3yjo0xSxgGhabk5Iu1soD3OxhUyIFcxaluhwkiVINt3Jhy7G7VJTlEwkk21A
oOrQxUsJH0f2GXjYShS1r9qLPzLf7ykcOm62jHGmLZVZujBzLIdNk1bljP9VuGW+
cISBwzkNeEMMFufcL2xh6s/oiUnXicFWvG7E6ioPnayYXrHy3Rh68XLnhfpzeCzv
bz/I4yMV38qGo/cAY2OJpXUuuD/ZbI5rT+lRBEkDW1kxHP8cpwkRwGopV8+gX2KS
UucIIN4l8/rrNDEX8T0b5U+BUqiO7Z5YnxCya/H0ZIwmQnTlLRTU2fW+OGG+xyIr
jMi/0l6/yWPUkIAkNtvS/yO7USRVLPbtGVk3Qre6HcqacCXzEjINcJhGEVg83Y8n
M+Y+a9J0lUnHytMSFZE85h88OseRS2QwqjozUo2j1DowmhSSUv9Na5Ae22ycciBk
EZSq8a4rSlwqthaELNpeoTLUk6iVoUkK/iLvaMvrkdj9yJY1O/gvlfN2aiNTST/2
bd+PA4RBToG9rXn6vNkUWdbLibU=
-----END CERTIFICATE-----
```

Select to view the .p7b content (Root + ICA-01)

Global Virtual TPM CA - 01:

```
-----BEGIN CERTIFICATE-----
MIIRKQYJKoZIhvcNAQcCoIIRGjCCERYCAQExADCCBbMGCSqGSIb3DQEHAaCCBaQE
ggWgMIIFnDCCA4SgAwIBAgITMwAAAALA0XtLj5ecNQAAAAAAAjANBgkqhkiG9w0B
AQwFADBpMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
aW9uMTowOAYDVQQDEzFBenVyZSBWaXJ0dWFsIFRQTSBSb290IENlcnRpZmljYXRl
IEF1dGhvcml0eSAyMDIzMB4XDTIzMDYwODE3NTMwNFoXDTI1MTEwMzE3NTMwNFow
JTEjMCEGA1UEAxMaR2xvYmFsIFZpcnR1YWwgVFBNIENBIC0gMDEwggEiMA0GCSqG
SIb3DQEBAQUAA4IBDwAwggEKAoIBAQC/NqouHGBovTadw1GLMQYNxWrEciPSh7gE
7VxsfbbPCE0SfTO80OF2raLdRYN2gEWE2Dr8+TDUuAb/WBFyczhU1aHFPssg8B3/
DT6pTXlDlohLLPWkjYU+OuT1/Ls7RzjQBe2se/MJyPaIJXI6KgCwePw7EcWFChe8
aCTUMHYBG0Ju4xNlMTUd/tcu6a53CXn6Nq48umwlaJelRh+i1f0vcwB2CY/v+Rli
wb/8DM5Ed9FUHZOKyp5Vnaw9GWloM46sLQT/fdHB0jmugfNZzafkkhQAYiNL3jYN
YFZH5/IgUfYJ/yybwnwoxOdV2NV0Q2i+P5Pcb0WNGaJY47aqOj8BAgMBAAGjggF/
MIIBezASBgNVHRMBAf8ECDAGAQH/AgEAMA4GA1UdDwEB/wQEAwICBDAXBgNVHSUE
EDAOBgVngQUIAQYFZ4EFCAMwHQYDVR0OBBYEFP/2zueowUhpKMuKS/LYgYG1bYCB
MB8GA1UdIwQYMBaAFEv+JlqUwfYzw4NIJt3z5bBksqqVMHYGA1UdHwRvMG0wa6Bp
oGeGZWh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL0F6dXJlJTIw
VmlydHVhbCUyMFRQTSUyMFJvb3QlMjBDZXJ0aWZpY2F0ZSUyMEF1dGhvcml0eSUy
MDIwMjMuY3JsMIGDBggrBgEFBQcBAQR3MHUwcwYIKwYBBQUHMAKGZ2h0dHA6Ly93
d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvQXp1cmUlMjBWaXJ0dWFsJTIw
VFBNJTIwUm9vdCUyMENlcnRpZmljYXRlJTIwQXV0aG9yaXR5JTIwMjAyMy5jcnQw
DQYJKoZIhvcNAQEMBQADggIBAEhTwx26W+Xap7zXExbAwnHYtN6kB4dIGXdgQIiQ
y5OQltsSj2jx7qZ/af5n5OnTBQ+gXM8siVipgaAIdBkbGgOjCb6b6MTe1YpFAH4f
Qv8eVwTVDziBMD0EKI30h0JbFKLdSdKe48O9Lw+T2b0PBXvMFJOSdZT7meGIkpNx
SqmAZ+RNyreLxil9knNjF5ymPT0RcGK52+MwGlElBb/jc+snhr+ZJZ1grjFky9Nz
jCTiE5SG+6H3YgiHCqfXr0L3NRt/QZ5IgkuGkNPeMvn4JjevFwAhXFxBqJYJ7mY6
1MJuWTdyhhoUJgzmZo1hS+GNyuMKaKBLreUwtc1y7LRH3YGGed57HbQ9bmyMdhO7
x8KZNrBDX2/cRLzrCmpSUldmKMu9G4dpzXpde4pFMObiVFrGRq8/9HMOJwZlQvzh
wQp0PUMY/gIU5rf23n1M1M36tM5g5CEzxQUGtVaG9ABTJQ2zijD5wDo840vbznyK
t3ihimrUs+LqpPDNXyxbwvibcZidwSdhu0QmUoyYsgSP2Zff5E8ks53h2xQSM3zz
2qaWVS1vVqG4zC0EfRnO65ogPPfrtK6ZiFmVHSWP9vPkFcUNYDnYQXW/TArO/JCe
2I++GClM7AcDQwWLxcopzskGQdHNM1zMsprRRwYaVpTJH67xeNda6+Y7IOPJYTvy
oXHPoIILVDCCBZwwggOEoAMCAQICEzMAAAACwNF7S4+XnDUAAAAAAAIwDQYJKoZI
hvcNAQEMBQAwaTELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
b3JhdGlvbjE6MDgGA1UEAxMxQXp1cmUgVmlydHVhbCBUUE0gUm9vdCBDZXJ0aWZp
Y2F0ZSBBdXRob3JpdHkgMjAyMzAeFw0yMzA2MDgxNzUzMDRaFw0yNTExMDMxNzUz
MDRaMCUxIzAhBgNVBAMTGkdsb2JhbCBWaXJ0dWFsIFRQTSBDQSAtIDAxMIIBIjAN
BgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAvzaqLhxgaL02ncNRizEGDcVqxHIj
0oe4BO1cbH22zwhNEn0zvNDhdq2i3UWDdoBFhNg6/Pkw1LgG/1gRcnM4VNWhxT7L
IPAd/w0+qU15Q5aISyz1pI2FPjrk9fy7O0c40AXtrHvzCcj2iCVyOioAsHj8OxHF
hQoXvGgk1DB2ARtCbuMTZTE1Hf7XLumudwl5+jauPLpsJWiXpUYfotX9L3MAdgmP
7/kZYsG//AzORHfRVB2TisqeVZ2sPRlpaDOOrC0E/33RwdI5roHzWc2n5JIUAGIj
S942DWBWR+fyIFH2Cf8sm8J8KMTnVdjVdENovj+T3G9FjRmiWOO2qjo/AQIDAQAB
o4IBfzCCAXswEgYDVR0TAQH/BAgwBgEB/wIBADAOBgNVHQ8BAf8EBAMCAgQwFwYD
VR0lBBAwDgYFZ4EFCAEGBWeBBQgDMB0GA1UdDgQWBBT/9s7nqMFIaSjLikvy2IGB
tW2AgTAfBgNVHSMEGDAWgBRL/iZalMH2M8ODSCbd8+WwZLKqlTB2BgNVHR8EbzBt
MGugaaBnhmVodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9BenVy
ZSUyMFZpcnR1YWwlMjBUUE0lMjBSb290JTIwQ2VydGlmaWNhdGUlMjBBdXRob3Jp
dHklMjAyMDIzLmNybDCBgwYIKwYBBQUHAQEEdzB1MHMGCCsGAQUFBzAChmdodHRw
Oi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL0F6dXJlJTIwVmlydHVh
bCUyMFRQTSUyMFJvb3QlMjBDZXJ0aWZpY2F0ZSUyMEF1dGhvcml0eSUyMDIwMjMu
Y3J0MA0GCSqGSIb3DQEBDAUAA4ICAQBIU8Mdulvl2qe81xMWwMJx2LTepAeHSBl3
YECIkMuTkJbbEo9o8e6mf2n+Z+Tp0wUPoFzPLIlYqYGgCHQZGxoDowm+m+jE3tWK
RQB+H0L/HlcE1Q84gTA9BCiN9IdCWxSi3UnSnuPDvS8Pk9m9DwV7zBSTknWU+5nh
iJKTcUqpgGfkTcq3i8YpfZJzYxecpj09EXBiudvjMBpRJQW/43PrJ4a/mSWdYK4x
ZMvTc4wk4hOUhvuh92IIhwqn169C9zUbf0GeSIJLhpDT3jL5+CY3rxcAIVxcQaiW
Ce5mOtTCblk3coYaFCYM5maNYUvhjcrjCmigS63lMLXNcuy0R92Bhnneex20PW5s
jHYTu8fCmTawQ19v3ES86wpqUlJXZijLvRuHac16XXuKRTDm4lRaxkavP/RzDicG
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
dmojU0k/9m3fjwOEQU6Bva15+rzZFFnWy4m1MQA=
-----END CERTIFICATE-----

```

Select to view the intermediate CA content (ICA-01)

"Global Virtual TPM CA - 01" (intermediate CA) [.cer]:

```

-----BEGIN CERTIFICATE-----
MIIFnDCCA4SgAwIBAgITMwAAAALA0XtLj5ecNQAAAAAAAjANBgkqhkiG9w0BAQwF
ADBpMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
MTowOAYDVQQDEzFBenVyZSBWaXJ0dWFsIFRQTSBSb290IENlcnRpZmljYXRlIEF1
dGhvcml0eSAyMDIzMB4XDTIzMDYwODE3NTMwNFoXDTI1MTEwMzE3NTMwNFowJTEj
MCEGA1UEAxMaR2xvYmFsIFZpcnR1YWwgVFBNIENBIC0gMDEwggEiMA0GCSqGSIb3
DQEBAQUAA4IBDwAwggEKAoIBAQC/NqouHGBovTadw1GLMQYNxWrEciPSh7gE7Vxs
fbbPCE0SfTO80OF2raLdRYN2gEWE2Dr8+TDUuAb/WBFyczhU1aHFPssg8B3/DT6p
TXlDlohLLPWkjYU+OuT1/Ls7RzjQBe2se/MJyPaIJXI6KgCwePw7EcWFChe8aCTU
MHYBG0Ju4xNlMTUd/tcu6a53CXn6Nq48umwlaJelRh+i1f0vcwB2CY/v+Rliwb/8
DM5Ed9FUHZOKyp5Vnaw9GWloM46sLQT/fdHB0jmugfNZzafkkhQAYiNL3jYNYFZH
5/IgUfYJ/yybwnwoxOdV2NV0Q2i+P5Pcb0WNGaJY47aqOj8BAgMBAAGjggF/MIIB
ezASBgNVHRMBAf8ECDAGAQH/AgEAMA4GA1UdDwEB/wQEAwICBDAXBgNVHSUEEDAO
BgVngQUIAQYFZ4EFCAMwHQYDVR0OBBYEFP/2zueowUhpKMuKS/LYgYG1bYCBMB8G
A1UdIwQYMBaAFEv+JlqUwfYzw4NIJt3z5bBksqqVMHYGA1UdHwRvMG0wa6BpoGeG
ZWh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL0F6dXJlJTIwVmly
dHVhbCUyMFRQTSUyMFJvb3QlMjBDZXJ0aWZpY2F0ZSUyMEF1dGhvcml0eSUyMDIw
MjMuY3JsMIGDBggrBgEFBQcBAQR3MHUwcwYIKwYBBQUHMAKGZ2h0dHA6Ly93d3cu
bWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvQXp1cmUlMjBWaXJ0dWFsJTIwVFBN
JTIwUm9vdCUyMENlcnRpZmljYXRlJTIwQXV0aG9yaXR5JTIwMjAyMy5jcnQwDQYJ
KoZIhvcNAQEMBQADggIBAEhTwx26W+Xap7zXExbAwnHYtN6kB4dIGXdgQIiQy5OQ
ltsSj2jx7qZ/af5n5OnTBQ+gXM8siVipgaAIdBkbGgOjCb6b6MTe1YpFAH4fQv8e
VwTVDziBMD0EKI30h0JbFKLdSdKe48O9Lw+T2b0PBXvMFJOSdZT7meGIkpNxSqmA
Z+RNyreLxil9knNjF5ymPT0RcGK52+MwGlElBb/jc+snhr+ZJZ1grjFky9NzjCTi
E5SG+6H3YgiHCqfXr0L3NRt/QZ5IgkuGkNPeMvn4JjevFwAhXFxBqJYJ7mY61MJu
WTdyhhoUJgzmZo1hS+GNyuMKaKBLreUwtc1y7LRH3YGGed57HbQ9bmyMdhO7x8KZ
NrBDX2/cRLzrCmpSUldmKMu9G4dpzXpde4pFMObiVFrGRq8/9HMOJwZlQvzhwQp0
PUMY/gIU5rf23n1M1M36tM5g5CEzxQUGtVaG9ABTJQ2zijD5wDo840vbznyKt3ih
imrUs+LqpPDNXyxbwvibcZidwSdhu0QmUoyYsgSP2Zff5E8ks53h2xQSM3zz2qaW
VS1vVqG4zC0EfRnO65ogPPfrtK6ZiFmVHSWP9vPkFcUNYDnYQXW/TArO/JCe2I++
GClM7AcDQwWLxcopzskGQdHNM1zMsprRRwYaVpTJH67xeNda6+Y7IOPJYTvyoXHP
-----END CERTIFICATE-----

```

Select to view the .p7b content (Root + ICA-03)

Global Virtual TPM CA - 03:

```
-----BEGIN CERTIFICATE-----
MIIRKQYJKoZIhvcNAQcCoIIRGjCCERYCAQExADCCBbMGCSqGSIb3DQEHAaCCBaQE
ggWgMIIFnDCCA4SgAwIBAgITMwAAAAknQOWscnsOpgAAAAAACTANBgkqhkiG9w0B
AQwFADBpMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
aW9uMTowOAYDVQQDEzFBenVyZSBWaXJ0dWFsIFRQTSBSb290IENlcnRpZmljYXRl
IEF1dGhvcml0eSAyMDIzMB4XDTI1MDQyNDE4MDExN1oXDTI3MDQyNDE4MDExN1ow
JTEjMCEGA1UEAxMaR2xvYmFsIFZpcnR1YWwgVFBNIENBIC0gMDMwggEiMA0GCSqG
SIb3DQEBAQUAA4IBDwAwggEKAoIBAQDYGYtis5ka0cxQkhU11jslgX6wzjR/UXQI
FdUn8juTUMJl91VokwUPX3WfXeog7mtbWyYWD8SI0BSnchRGlV8u3AhcW61/HetH
qmILtD0c75UATi+gsTQnpwKPA/m38MGGyXFETr3xHXjilUPfIhmxO4ImuNJ0R95b
ZYhxbLYmOZpVUcj8oz980An8HlIqSzrskQR6NiuEmikHkHc1/CpoNunrr8kQNPF6
gxexIrvXsKLUAuUqnNtcQWc/8Er5EN9+TdX6AOjUmKriVGbCInP1m/aC+DWH/+aJ
/8aDpKze6fe7OHh2BL9hxqIsmJAStIh4siRdLYTt8hKGmkdzOWnRAgMBAAGjggF/
MIIBezASBgNVHRMBAf8ECDAGAQH/AgEAMA4GA1UdDwEB/wQEAwICBDAXBgNVHSUE
EDAOBgVngQUIAQYFZ4EFCAMwHQYDVR0OBBYEFGcJhvj5gV6TrfnJZOcUCtqZywot
MB8GA1UdIwQYMBaAFEv+JlqUwfYzw4NIJt3z5bBksqqVMHYGA1UdHwRvMG0wa6Bp
oGeGZWh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL0F6dXJlJTIw
VmlydHVhbCUyMFRQTSUyMFJvb3QlMjBDZXJ0aWZpY2F0ZSUyMEF1dGhvcml0eSUy
MDIwMjMuY3JsMIGDBggrBgEFBQcBAQR3MHUwcwYIKwYBBQUHMAKGZ2h0dHA6Ly93
d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvQXp1cmUlMjBWaXJ0dWFsJTIw
VFBNJTIwUm9vdCUyMENlcnRpZmljYXRlJTIwQXV0aG9yaXR5JTIwMjAyMy5jcnQw
DQYJKoZIhvcNAQEMBQADggIBAJPP3Z2z1zhzUS3qSRVgyoUVnaxCGuMHzPQAZuoP
BVpzwKnv4HqyjMgT8pBtQqxkqAsg7KiqbPfO97bMCHcuqkkfHjw8yg6IYt01RjUj
VPKqlrsY2iw7hFWNWr8SGMa10JdNYNyf5dxob5+mKAwEOhLzKNwq9rM/uIvZky77
pNlyRLt55XEPfBMYdI9I8uQ5Uqmrw7mVJfERMfTBhSQF9BrcajAsaLcs7qEUyj0y
UdJfcgZkfCoUEUSPr3OwLHaYeV1J6VidhIYsYo53sXXal91d60NspYgei2nJFei/
+R3ESWnGbPBW+EQ4FbvZXxu57zUMX9mM7lC+GoXLvA6/vtKShEi9ZXl2PSnBQ/R2
A7b3AXyg4fmMLFausEk6OiuU8E/bvp+gPLOJ8YrX7SAJVuEn+koJaK5G7os5DMIh
7/KMl9cI9WxPwqoWjp4VBfrF4hDOCmKWrqtFUDQCML8qD8RTxlQKQtgeGAcNDfoA
uL9KVtSG5/iIhuyBEFYEHa3vRWbSaHCUzaHJsTmLcz4cp1VDdepzqZRVuErBzJKF
nBXbzRNW32EFmcAUKZImIsE5dgB7y7eiijf33VWNfWmK05fxzQziWFWRYlET4SVc
3jMnPBiY3N8BfK8EBOYbLvzo0qn2n3SAmPhYX3Ag6vbbIHd4Qc8DQKHRV0PB8D3j
PGmDoIILVDCCBZwwggOEoAMCAQICEzMAAAAJJ0DlrHJ7DqYAAAAAAAkwDQYJKoZI
hvcNAQEMBQAwaTELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
b3JhdGlvbjE6MDgGA1UEAxMxQXp1cmUgVmlydHVhbCBUUE0gUm9vdCBDZXJ0aWZp
Y2F0ZSBBdXRob3JpdHkgMjAyMzAeFw0yNTA0MjQxODAxMTdaFw0yNzA0MjQxODAx
MTdaMCUxIzAhBgNVBAMTGkdsb2JhbCBWaXJ0dWFsIFRQTSBDQSAtIDAzMIIBIjAN
BgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA2BmLYrOZGtHMUJIVNdY7JYF+sM40
f1F0CBXVJ/I7k1DCZfdVaJMFD191n13qIO5rW1smFg/EiNAUp3IURpVfLtwIXFut
fx3rR6piC7Q9HO+VAE4voLE0J6cCjwP5t/DBhslxRE698R144pVD3yIZsTuCJrjS
dEfeW2WIcWy2JjmaVVHI/KM/fNAJ/B5SKks67JEEejYrhJopB5B3NfwqaDbp66/J
EDTxeoMXsSK717Ci1ALlKpzbXEFnP/BK+RDffk3V+gDo1Jiq4lRmwiJz9Zv2gvg1
h//mif/Gg6Ss3un3uzh4dgS/YcaiLJiQErSIeLIkXS2E7fIShppHczlp0QIDAQAB
o4IBfzCCAXswEgYDVR0TAQH/BAgwBgEB/wIBADAOBgNVHQ8BAf8EBAMCAgQwFwYD
VR0lBBAwDgYFZ4EFCAEGBWeBBQgDMB0GA1UdDgQWBBRnCYb4+YFek635yWTnFAra
mcsKLTAfBgNVHSMEGDAWgBRL/iZalMH2M8ODSCbd8+WwZLKqlTB2BgNVHR8EbzBt
MGugaaBnhmVodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9BenVy
ZSUyMFZpcnR1YWwlMjBUUE0lMjBSb290JTIwQ2VydGlmaWNhdGUlMjBBdXRob3Jp
dHklMjAyMDIzLmNybDCBgwYIKwYBBQUHAQEEdzB1MHMGCCsGAQUFBzAChmdodHRw
Oi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL0F6dXJlJTIwVmlydHVh
bCUyMFRQTSUyMFJvb3QlMjBDZXJ0aWZpY2F0ZSUyMEF1dGhvcml0eSUyMDIwMjMu
Y3J0MA0GCSqGSIb3DQEBDAUAA4ICAQCTz92ds9c4c1Et6kkVYMqFFZ2sQhrjB8z0
AGbqDwVac8Cp7+B6sozIE/KQbUKsZKgLIOyoqmz3zve2zAh3LqpJHx48PMoOiGLd
NUY1I1Tyqpa7GNosO4RVjVq/EhjGtdCXTWDcn+XcaG+fpigMBDoS8yjcKvazP7iL
2ZMu+6TZckS7eeVxD3wTGHSPSPLkOVKpq8O5lSXxETH0wYUkBfQa3GowLGi3LO6h
FMo9MlHSX3IGZHwqFBFEj69zsCx2mHldSelYnYSGLGKOd7F12pfdXetDbKWIHotp
yRXov/kdxElpxmzwVvhEOBW72V8bue81DF/ZjO5QvhqFy7wOv77SkoRIvWV5dj0p
wUP0dgO29wF8oOH5jCxWrrBJOjorlPBP276foDyzifGK1+0gCVbhJ/pKCWiuRu6L
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
dmojU0k/9m3fjwOEQU6Bva15+rzZFFnWy4m1MQA=
-----END CERTIFICATE-----

```

Select to view the intermediate CA content (ICA-03)

"Global Virtual TPM CA - 03" (intermediate CA) [.cer]:

```

-----BEGIN CERTIFICATE-----
MIIFnDCCA4SgAwIBAgITMwAAAAknQOWscnsOpgAAAAAACTANBgkqhkiG9w0BAQwF
ADBpMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
MTowOAYDVQQDEzFBenVyZSBWaXJ0dWFsIFRQTSBSb290IENlcnRpZmljYXRlIEF1
dGhvcml0eSAyMDIzMB4XDTI1MDQyNDE4MDExN1oXDTI3MDQyNDE4MDExN1owJTEj
MCEGA1UEAxMaR2xvYmFsIFZpcnR1YWwgVFBNIENBIC0gMDMwggEiMA0GCSqGSIb3
DQEBAQUAA4IBDwAwggEKAoIBAQDYGYtis5ka0cxQkhU11jslgX6wzjR/UXQIFdUn
8juTUMJl91VokwUPX3WfXeog7mtbWyYWD8SI0BSnchRGlV8u3AhcW61/HetHqmIL
tD0c75UATi+gsTQnpwKPA/m38MGGyXFETr3xHXjilUPfIhmxO4ImuNJ0R95bZYhx
bLYmOZpVUcj8oz980An8HlIqSzrskQR6NiuEmikHkHc1/CpoNunrr8kQNPF6gxex
IrvXsKLUAuUqnNtcQWc/8Er5EN9+TdX6AOjUmKriVGbCInP1m/aC+DWH/+aJ/8aD
pKze6fe7OHh2BL9hxqIsmJAStIh4siRdLYTt8hKGmkdzOWnRAgMBAAGjggF/MIIB
ezASBgNVHRMBAf8ECDAGAQH/AgEAMA4GA1UdDwEB/wQEAwICBDAXBgNVHSUEEDAO
BgVngQUIAQYFZ4EFCAMwHQYDVR0OBBYEFGcJhvj5gV6TrfnJZOcUCtqZywotMB8G
A1UdIwQYMBaAFEv+JlqUwfYzw4NIJt3z5bBksqqVMHYGA1UdHwRvMG0wa6BpoGeG
ZWh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL0F6dXJlJTIwVmly
dHVhbCUyMFRQTSUyMFJvb3QlMjBDZXJ0aWZpY2F0ZSUyMEF1dGhvcml0eSUyMDIw
MjMuY3JsMIGDBggrBgEFBQcBAQR3MHUwcwYIKwYBBQUHMAKGZ2h0dHA6Ly93d3cu
bWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvQXp1cmUlMjBWaXJ0dWFsJTIwVFBN
JTIwUm9vdCUyMENlcnRpZmljYXRlJTIwQXV0aG9yaXR5JTIwMjAyMy5jcnQwDQYJ
KoZIhvcNAQEMBQADggIBAJPP3Z2z1zhzUS3qSRVgyoUVnaxCGuMHzPQAZuoPBVpz
wKnv4HqyjMgT8pBtQqxkqAsg7KiqbPfO97bMCHcuqkkfHjw8yg6IYt01RjUjVPKq
lrsY2iw7hFWNWr8SGMa10JdNYNyf5dxob5+mKAwEOhLzKNwq9rM/uIvZky77pNly
RLt55XEPfBMYdI9I8uQ5Uqmrw7mVJfERMfTBhSQF9BrcajAsaLcs7qEUyj0yUdJf
cgZkfCoUEUSPr3OwLHaYeV1J6VidhIYsYo53sXXal91d60NspYgei2nJFei/+R3E
SWnGbPBW+EQ4FbvZXxu57zUMX9mM7lC+GoXLvA6/vtKShEi9ZXl2PSnBQ/R2A7b3
AXyg4fmMLFausEk6OiuU8E/bvp+gPLOJ8YrX7SAJVuEn+koJaK5G7os5DMIh7/KM
l9cI9WxPwqoWjp4VBfrF4hDOCmKWrqtFUDQCML8qD8RTxlQKQtgeGAcNDfoAuL9K
VtSG5/iIhuyBEFYEHa3vRWbSaHCUzaHJsTmLcz4cp1VDdepzqZRVuErBzJKFnBXb
zRNW32EFmcAUKZImIsE5dgB7y7eiijf33VWNfWmK05fxzQziWFWRYlET4SVc3jMn
PBiY3N8BfK8EBOYbLvzo0qn2n3SAmPhYX3Ag6vbbIHd4Qc8DQKHRV0PB8D3jPGmD
-----END CERTIFICATE-----

```

### What Microsoft owned trusted certificates are built into Azure VMs?

For Windows VMs, Windows CA certificate is built in UEFI firmware. For Linux VMs, Microsoft UEFI CA certificate is built in UEFI firmware.

For Azure Linux VMs only, `Azure Services Linux Kmod PCA` certificate is also added in UEFI firmware for all Linux distributions. Linux Kmod PCA is used to sign Microsoft owned kernel modules.

Linux Kmod PCA certificate is added to make customer experience smoother when using Microsoft solutions like Azure Site Recovery (Site recovery) which installs a kernel module. The Site recovery kernel module loads without any customer action to supply a key as Site recovery kernel module is signed using the trusted ‘Azure Services Linux Kmod PCA’ certificate.

#### Download instructions

Package certificates, composed of .p7b and .cer reveal the signing and certificate authority. Copy the relevant content and use certificate tooling to inspect and assess details of certificates.

Select to download the .crt that follows for the Microsoft Windows CA 

[Microsoft Windows CA](https://go.microsoft.com/fwlink/p/?linkid=321192)

Select to download the .crt that follows for the Microsoft UEFI CA 

[Microsoft UEFI CA](https://go.microsoft.com/fwlink/p/?linkid=2239776)

Select to view the .p7b content

Azure services Linux kmod PCA certificate:

```
-----BEGIN CERTIFICATE-----
MIIGrjCCBJagAwIBAgITMwAAAATCM9cMfybr0QAAAAAABDANBgkqhkiG9w0BAQwF
ADBbMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
MSwwKgYDVQQDEyNNaWNyb3NvZnQgUlNBIFNlcnZpY2VzIFJvb3QgQ0EgMjAyMTAe
Fw0yMzA4MDgxODE0NTVaFw0zODA4MDgxODI0NTVaMFUxCzAJBgNVBAYTAlVTMR4w
HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHUF6dXJlIFNl
cnZpY2VzIExpbnV4IEttb2QgUENBMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIIC
CgKCAgEAwQAMp1T5lFW9RKdeuXVts2Wcim44ObsCNa4PVMfdpiPNOCPCYFBkyB2o
k/s/8Is5pYxNkjcvNdYPKW+8E8IC1HU6Vj+jR+sdtuFX1mbYV9I4LWNZEWHr/FHn
A2lk8QLGwj9HfElQxKNjEtgkJPfvtp5B3XlPkhMzxZCdzqWZk9qNd8l9PaccSidC
m/BB8dBbf7MirXAphT9FPn5gNAUqmc2Sz2/HcGPp0n1X3VMf/9gemri/MEKScO6r
byLT7rpLnVUNWfSVARM35e0cFkyGfYtDh4LgrNUnl2lpZg/nvCdeR4k4mgYbYGWQ
EppENAJ8Hh3gxKiG7phYShxxG+x5NZdIqhBa71VGgrlqys/9ybZNsqW5iBjleflQ
L7SWz4vbZGkVNDQ1tpWF/UrM4rHfmLiXhofDmN3/lYZ4veeyMkktvmLk9RUcO9X4
MzKVipZGr9a6gDIU5obNAuD5enny3ejD1ny6azSbRY6YYgJx/zgxg93wbVgVMljy
ke8y0QDtZfDi078AuOWhrUzw4t87NfdlZ/NmAJIcildRaICDes6/kW5AOyCfZqV4
vXVD7dokC8pbt7hvmTZeWrGBTSPvo8PiJvRdhQYE2lDiOjtXFElcDG6/xs4XLrUy
P/U1L2Q7F7GgA46KhQILqYkJhmEgrSVc4EsZ2xDFmdHRpSM5EjsCAwEAAaOCAW8w
ggFrMA4GA1UdDwEB/wQEAwIBhjAQBgkrBgEEAYI3FQEEAwIBADAdBgNVHQ4EFgQU
aXzE9BoiCaer0GBMHxlvTYxXNdkwGQYJKwYBBAGCNxQCBAweCgBTAHUAYgBDAEEw
DwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBQODLFkab0tsdVrJqZH6lZOgMPt
ijBmBgNVHR8EXzBdMFugWaBXhlVodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtp
b3BzL2NybC9NaWNyb3NvZnQlMjBSU0ElMjBTZXJ2aWNlcyUyMFJvb3QlMjBDQSUy
MDIwMjEuY3JsMHMGCCsGAQUFBwEBBGcwZTBjBggrBgEFBQcwAoZXaHR0cDovL3d3
dy5taWNyb3NvZnQuY29tL3BraW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBSU0ElMjBT
ZXJ2aWNlcyUyMFJvb3QlMjBDQSUyMDIwMjEuY3J0MA0GCSqGSIb3DQEBDAUAA4IC
AQB2eZw8jfATH/wiLEpIA4Npc3+f6KhmsMlbC5o+ud3mkKMy7O3IgUP3nITvtFPV
ekyfGQZB3Hm0dOVCNaGZ6BLYD4iEXD6I1Z2XqUayKitGZaagOjAjr2piRpcwGSql
V8lVq1EfKH/iJYf/408D/hkH8M/6TQqZRSjpsmeX/PxYXKZrEKr6XQsUy1dGq7oR
UTc6WU0iy7WMagrqQAQlGpZpSehhoGvodwJoSGhPM9/GDIiEiwXT2hkswJX8/MQQ
T8O9Is0aLAgf+bwuk9Ng8TDNr/m8B2VXYrfcW2OTlJy7kXh8LmiQfxV7JtS8UKSx
OL+AXJtcAn3MBMscG+Lb3SGoQywGeNqCeeglIvMeOYhFrQ5WT3Ob04ZHAbt+aQ/r
psceMSMsE3RwcCANZhq98/6kh8cUsblmJbBgUV4pFJtEMjmUByZa8aRfABM7FUZ4
My/GJL6iPgcqzCTofkc7Z50Fa3NjXEyGzWMae3mS/djRePlr3RaTBTELCdtHVG/H
OFIyldD/wdlzvoOIkNc7UoIQPbjvxM0qCb6ruQiifCjvo8KFXjdmft/Dh3h60idH
g2Zz8q2u48vpBVBwxv5mJOF6ioYTpJpMtLfFgAOdTxIma89Ibja866Sr73Sg/J0b
KoeRpZWk8vqiJUl9PAk+JMqy8Fe/DoKq5OYT3zeZuVxGUQ==
-----END CERTIFICATE-----

Linux kmod PCA Details

Serial Number # 3300000004c233d70c7f26ebd1000000000004
Valid Until # 08/Aug/2038

```
