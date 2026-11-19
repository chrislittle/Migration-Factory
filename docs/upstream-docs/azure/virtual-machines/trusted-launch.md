# Trusted Launch for Azure VMs - Azure Virtual Machines | Microsoft Learn

**Applies to:** ✔️ Linux VMs ✔️ Windows VMs ✔️ Flexible scale sets ✔️ Uniform scale sets

Azure Trusted Launch provides an easy way to improve the security of [Generation 2](generation-2) virtual machines (VMs). Trusted Launch protects against advanced and persistent attack techniques by providing enhanced protection against bootkits, rootkits, and low-level malware attacks. It uses several coordinated infrastructure technologies that you can enable independently. Each technology adds another layer of defense against sophisticated threats.

Trusted Launch is supported for both x64 and Arm64 architectures.

Important

- Trusted Launch is the default state for newly created Azure Gen2 VM and scale sets. See the [Trusted Launch FAQs](trusted-launch-faq) if your new VM requires features that [aren't supported with Trusted launch](trusted-launch#unsupported-features).
- You can upgrade existing Azure Gen1 VMs to Gen2-Trusted launch to enable Secure Boot and vTPM. See [Upgrade existing Gen1 VMs to Gen2-Trusted launch](trusted-launch-existing-vm-gen-1).
- [Existing VMs](overview) can have Trusted Launch enabled after being created. For more information, see [Enable Trusted Launch on existing Gen2 VMs](trusted-launch-existing-vm).
- Existing [virtual machine scale sets](../virtual-machine-scale-sets/overview) can have Trusted Launch enabled after being created. For more information, see [Enable Trusted Launch on existing scale set](trusted-launch-existing-vmss).

## Benefits

- Securely deploy VMs with verified boot loaders, operating system (OS) kernels, and drivers.
- Securely protect keys, certificates, and secrets in the VMs.
- Gain insights and confidence of the entire boot chain's integrity.
- Ensure that workloads are trusted and verifiable.

## Virtual machines sizes

| Type | Supported size families | Currently not supported size families | Not supported size families |
| --- | --- | --- | --- |
| [General purpose](sizes/overview#general-purpose) | [B-family](sizes/general-purpose/b-family), [D-family](sizes/general-purpose/d-family), [Dpsv6-series](sizes/general-purpose/dpsv6-series)^1^, [Dplsv6-series](sizes/general-purpose/dplsv6-series)^1^ | [Dpsv5-series](sizes/general-purpose/dpsv5-series), [Dpdsv5-series](sizes/general-purpose/dpdsv5-series), [Dplsv5-series](sizes/general-purpose/dplsv5-series), [Dpldsv5-series](sizes/general-purpose/dpldsv5-series) | [A-family](sizes/general-purpose/a-family), [Dv2-series](sizes/general-purpose/dv2-series), [Dv3-series](sizes/general-purpose/dv3-series), [DC-Confidential-family](sizes/general-purpose/dc-family) |
| [Compute optimized](sizes/overview#compute-optimized) | [F-family](sizes/compute-optimized/f-family), [Fx-family](sizes/compute-optimized/fx-family) | All sizes supported. |  |
| [Memory optimized](sizes/overview#memory-optimized) | [E-family](sizes/memory-optimized/e-family), [Eb-family](sizes/memory-optimized/eb-family), [Epsv6-series](sizes/memory-optimized/epsv6-series)^1^ | [Mbdsv4 sizes series (Preview)](sizes/memory-optimized/m-family) | [M-family](sizes/memory-optimized/m-family) except Mbdsv4 sizes series (Preview), [EC-Confidential-family](sizes/memory-optimized/ec-family) |
| [Storage optimized](sizes/overview#storage-optimized) | [L-family](sizes/storage-optimized/l-family) | All sizes supported. |  |
| [GPU](sizes/overview#gpu-accelerated) | [NC-family](sizes/gpu-accelerated/nc-family), [ND-family](sizes/gpu-accelerated/nv-family), [NV-family](sizes/gpu-accelerated/nv-family), [NDasrA100_v4-series](nda100-v4-series), [NDm_A100_v4-series](ndm-a100-v4-series) |  | [NC-series](nc-series), [NV-series](nv-series), [NP-series](np-series) |
| [High Performance Compute](sizes/overview#high-performance-compute) | [HBv2-series](sizes/high-performance-compute/hbv2-series-overview)^2^, [HBv3-series](sizes/high-performance-compute/hbv3-series-overview), [HBv4-series](sizes/high-performance-compute/hbv4-series-overview), [HBv5-series](sizes/high-performance-compute/hbv5-series-overview), [HC-series](sizes/high-performance-compute/hc-series-overview)^3^, [HX-series](sizes/high-performance-compute/hx-series-overview) | All sizes supported. |  |

^1^Arm64 [Cobalt 100](sizes/cobalt-overview)-based sizes that support Trusted Launch.

^2^HBv2-series is currently supported for Trusted Launch but is scheduled for retirement on May 31, 2027. For new HPC Trusted Launch deployments, prefer HBv5-series, HX-series, HBv4-series, or HBv3-series sizes.

^3^HC-series sizes (Standard\_HC44rs, Standard\_HC44-16rs, Standard\_HC44-32rs) are scheduled for retirement on May 31, 2027. After this date, remaining HC-series VMs will be deallocated and stop incurring charges, and HC-series will no longer have SLA or support. Sales of 1-year and 3-year Reserved Instances ended April 2, 2026. For new HPC Trusted Launch deployments, consider [HBv5-series](sizes/high-performance-compute/hbv5-series-overview) for higher performance and better price-performance, or [HX-series](sizes/high-performance-compute/hx-series-overview) for high-memory HPC workloads. Plan to transition off HC-series well before the retirement date to avoid disruption.

Note

- Installation of the *CUDA & GRID drivers on Secure Boot-enabled Windows VMs* doesn't require any extra steps.
- Installation of the *CUDA driver on Secure Boot-enabled Ubuntu VMs* requires extra steps. For more information, see [Install NVIDIA GPU drivers on N-series VMs running Linux](linux/n-series-driver-setup#cuda-drivers). Secure Boot should be disabled for installing CUDA drivers on other Linux VMs.
- Installation of the *GRID driver* requires Secure Boot to be disabled for Linux VMs.
- *Not supported* size families don't support [Generation 2](generation-2) VMs. Change the VM size to equivalent *supported size families* for enabling Trusted Launch.

## Operating systems supported

| OS | Version |
| --- | --- |
| Alma Linux | 8, 9, 10 |
| Azure Linux | 1.0, 2.0, 3.0 |
| Debian | 11, 12, 13 |
| Oracle Linux | 8.10, 9.6, 9.7, 10.1 |
| Red Hat Enterprise Linux | 8.6, 8.8, 8.10, 9.4, 9.5, 9.6, 9.7, 9.8, 10.0, 10.1, 10.2 |
| Rocky Linux from CIQ | 8.6, 8.10, 9.2, 9.4, 9.5, 9.6, 9.7 |
| SUSE Enterprise Linux | 15SP3, 15SP4, 15SP5, 15SP6, 15SP7, SLES 16 |
| Ubuntu Server | 18.04 LTS, 20.04 LTS, 22.04 LTS, 24.04 LTS, 26.04 LTS |
| Windows 10 | Pro, Enterprise, Enterprise Multi-Session \* |
| Windows 11 | Pro, Enterprise, Enterprise Multi-Session \* |
| Windows Server | 2016, 2019, 2022, 2022-Azure-Edition, 2025, 2025-Azure-Edition \* |

\* Variations of this OS are supported.

Note

Trusted Launch on Arm64 is supported when using applicable Arm64 Marketplace images for supported distributions and versions. For [Cobalt 100](sizes/cobalt-overview) sizes, deploy Trusted Launch using Arm64 images available in Azure Marketplace.

## More information

**Regions**:

- All public regions
- All Azure Government regions
- All Azure China regions

**Pricing**: Trusted Launch doesn't increase existing VM pricing costs.

## Unsupported features

Currently, the following VM features aren't supported with Trusted Launch:

- [Managed Image](capture-image-resource) (customers are encouraged to use [Azure Compute Gallery](trusted-launch-portal#trusted-launch-vm-supported-images)).
- [Linux VM Hibernation](linux/hibernate-resume-linux)

## Secure Boot

At the root of Trusted Launch is Secure Boot for your VM. Secure Boot, which is implemented in platform firmware, protects against the execution of malware-based rootkits and boot kits. Secure Boot works to ensure that only signed operating systems and drivers can boot. It establishes a "root of trust" for the software stack on your VM.

With Secure Boot enabled, all OS boot components (boot loader, kernel, kernel drivers) require trusted publishers signing. Both Windows and major Linux distributions support Secure Boot. If Secure Boot fails to authenticate that the image is signed by a trusted publisher, the VM fails to boot. For more information, see [Secure Boot](/en-us/windows-hardware/design/device-experiences/oem-secure-boot).

## vTPM

Trusted Launch also introduces virtual Trusted Platform Module (vTPM) for Azure VMs. This virtualized version of a hardware [Trusted Platform Module](/en-us/windows/security/information-protection/tpm/trusted-platform-module-overview) is compliant with the TPM2.0 spec. It serves as a dedicated secure vault for keys and measurements.

Trusted Launch provides your VM with its own dedicated TPM instance that runs in a secure environment outside the reach of any VM. The vTPM enables [attestation](/en-us/windows/security/information-protection/tpm/tpm-fundamentals#measured-boot-with-support-for-attestation) by measuring the entire boot chain of your VM (UEFI, OS, system, and drivers).

Trusted Launch uses the vTPM to perform remote attestation through the cloud. Attestations enable platform health checks and are used for making trust-based decisions. As a health check, Trusted Launch can cryptographically certify that your VM booted correctly.

If the process fails, possibly because your VM is running an unauthorized component, Microsoft Defender for Cloud issues integrity alerts. The alerts include details on which components failed to pass integrity checks.

## Virtualization-based security

[Virtualization-based security](/en-us/windows-hardware/design/device-experiences/oem-vbs) (VBS) uses the hypervisor to create a secure and isolated region of memory. Windows uses these regions to run various security solutions with increased protection against vulnerabilities and malicious exploits. Trusted Launch lets you enable hypervisor code integrity (HVCI) and Windows Defender Credential Guard.

HVCI is a powerful system mitigation that protects Windows kernel-mode processes against injection and execution of malicious or unverified code. It checks kernel mode drivers and binaries before they run, preventing unsigned files from loading into memory. Checks ensure that executable code can't be modified after it's allowed by HVCI to load. For more information about VBS and HVCI, see [Virtualization-based security and hypervisor-enforced code integrity](https://techcommunity.microsoft.com/t5/windows-insider-program/virtualization-based-security-vbs-and-hypervisor-enforced-code/m-p/240571).

With Trusted Launch and VBS, you can enable Windows Defender Credential Guard. Credential Guard isolates and protects secrets so that only privileged system software can access them. It helps prevent unauthorized access to secrets and credential theft attacks, like Pass-the-Hash attacks. For more information, see [Credential Guard](/en-us/windows/security/identity-protection/credential-guard/credential-guard).

## Microsoft Defender for Cloud integration

Trusted Launch is integrated with Defender for Cloud to ensure that your VMs are properly configured. Defender for Cloud continually assesses compatible VMs and issues relevant recommendations:

- **Recommendation to enable Secure Boot**: The Secure Boot recommendation only applies for VMs that support Trusted Launch. Defender for Cloud identifies VMs that have Secure boot disabled. It issues a low-severity recommendation to enable it.
- **Recommendation to enable vTPM**: If vTPM is enabled for VM, Defender for Cloud can use it to perform guest attestation and identify advanced threat patterns. If Defender for Cloud identifies VMs that support Trusted Launch with vTPM disabled, it issues a low-severity recommendation to enable it.
- **Recommendation to install guest attestation extension**: If your VM has Secure Boot and vTPM enabled but it doesn't have the Guest Attestation extension installed, Defender for Cloud issues low-severity recommendations to install the Guest Attestation extension on it. This extension allows Defender for Cloud to proactively attest and monitor the boot integrity of your VMs. Boot integrity is attested via remote attestation.
- **Attestation health assessment or boot integrity monitoring**: If your VM has Secure Boot and vTPM enabled and the Attestation extension installed, Defender for Cloud can remotely validate that your VM booted in a healthy way. This practice is known as boot integrity monitoring. Defender for Cloud issues an assessment that indicates the status of remote attestation.

    If your VMs are properly set up with Trusted Launch, Defender for Cloud can detect and alert you of VM health problems.
- **Alert for VM attestation failure**: Defender for Cloud periodically performs attestation on your VMs. The attestation also happens after your VM boots. If the attestation fails, it triggers a medium-severity alert.

    Note

    VM client boot attestation alerts surfaced in Microsoft Defender for Cloud are informational and are not currently presented in the Defender portal.

    VM attestation can fail for the following reasons:

    - The attested information, which includes a boot log, deviates from a trusted baseline. Any deviation can indicate that untrusted modules are loaded, and the OS could be compromised.
    - The attestation quote couldn't be verified to originate from the vTPM of the attested VM. An unverified origin can indicate that malware is present and could be intercepting traffic to the vTPM.

        Note

        Alerts are available for VMs with vTPM enabled and the Attestation extension installed. Secure Boot must be enabled for attestation to pass. Attestation fails if Secure Boot is disabled. If you must disable Secure Boot, you can suppress this alert to avoid false positives.
- **Alert for untrusted Linux kernel module**: For Trusted Launch with Secure Boot enabled, it's possible for a VM to boot even if a kernel driver fails validation and is prohibited from loading. If kernel driver validation failure happens, Defender for Cloud issues low-severity alerts. While there's no immediate threat, because the untrusted driver didn't load, these events should be investigated. Ask yourself:

    - Which kernel driver failed? Am I familiar with the failed kernel driver and do I expect it to load?
    - Is the exact version of the driver same as expected? Are the driver binaries intact? If failed driver is a partner driver, did the partner pass the OS compliance tests to get it signed?

## (General Availability) Trusted Launch as default

Important

Trusted Launch as Default is generally available for new Gen2 virtual machines (VMs) and virtual machine scale sets (scale sets). TLaD is a fast and zero-touch means of improving the security posture of new Gen2 based Azure VM and virtual machine scale sets deployments. When you register the subscription for this feature, Trusted Launch as Default sets any new Gen2 VMs or scale sets that you create through any client tools (like ARM template, Bicep, Terraform) to Trusted Launch VMs with secure boot and vTPM enabled by default. This change doesn't override inputs provided as part of the deployment code.

Azure portal, PowerShell, and CLI customers get Trusted Launch enabled by default.

### Enable TLaD (Trusted Launch as default)

To make this feature available for all VMs you create for your workloads by default, first register the feature `TrustedLaunchByDefaultPreview` under the `Microsoft.Compute` namespace on your virtual machine subscription. For more information, see [Set up preview features in Azure subscription](/en-us/azure/azure-resource-manager/management/preview-features).

To create a new Gen2 VM or scale set with Trusted Launch default, run your existing deployment script through Azure SDK, Terraform, or another method.

Note

Creating VMs defaults to Trusted Launch for Azure portal, CLI, or PowerShell regardless of registering the feature.

### VM and scale set deployments with TLaD

#### Existing behavior

To create Trusted launch VM & scale set, you need to add following securityProfile element in deployment:

```json
"securityProfile": {
    "securityType": "TrustedLaunch",
    "uefiSettings": {
        "secureBootEnabled": true,
        "vTpmEnabled": true,
    }
}
```

Absence of securityProfile element in deployment code deploys VM & scale set without enabling Trusted launch.

**Examples**

- [vm-windows-admincenter](https://github.com/Azure/azure-quickstart-templates/blob/master/quickstarts/microsoft.compute/vm-windows-admincenter/azuredeploy.json) – The Azure Resource Manager (ARM) template deploys Gen2 VM without enabling Trusted launch.
- [vm-simple-windows](https://github.com/Azure/azure-quickstart-templates/blob/master/quickstarts/microsoft.compute/vm-simple-windows/azuredeploy.json) – The ARM template deploys Trusted launch VM (without default as `securityProfile` is explicitly added to ARM template)

#### New behavior

By using API version 2025-11-01 or higher, Trusted Launch is enabled by default for new VMs and scale sets deployed if the following conditions are met:

- Source Marketplace [OS image supports Trusted launch](trusted-launch#operating-systems-supported).
- Source ACG OS image supports and is validated for Trusted launch.
- Source disk supports Trusted launch.
- [VM size supports Trusted launch](trusted-launch#virtual-machines-sizes).

The deployment doesn't default to Trusted Launch if one or more of the listed conditions aren't met, and completes successfully to create a new Gen2 VM and scale set without Trusted Launch.

You can choose to explicitly bypass the default for VM and scale set deployment by setting `Standard` as value of parameter `securityType` and using API version 2025-11-01 or higher. For more information, see [Can I disable Trusted Launch for a new VM deployment](trusted-launch-faq#can-i-disable-trusted-launch-for-a-new-vm-deployment).

#### Known limitations

***Unable to re-size VM or VMSS to un-supported Trusted launch VM size family (like M-Series) post default to Trusted launch.***

Re-sizing Trusted launch VM to [VM size family not supported with Trusted launch](trusted-launch#virtual-machines-sizes) will not be supported.

As mitigation, please register feature flag `UseStandardSecurityType` under `Microsoft.Compute` namespace AND roll-back VM from Trusted launch to Gen2-only (Non-Trusted launch) by setting `securityType = Standard` using available client tools (except Azure portal).

After a VM or VM scale set is created with Trusted Launch, you can't resize it to a VM size family that doesn't support Trusted Launch, such as an unsupported M-series size. To use an unsupported size, first deallocate the resource and change `securityType` to `Standard` by using Microsoft.Compute API version 2025-11-01 or later through a supported client tool. This operation isn't available in the Azure portal.

### Disable TLaD

To disable TLaD, unregister the preview feature `TrustedLaunchByDefaultPreview` under the `Microsoft.Compute` namespace on the virtual machine subscription. For specific VMs, you can bypass TLaD by setting the security type to `Standard`. For more information, see [Unregister preview feature](/en-us/azure/azure-resource-manager/management/preview-features#unregister-preview-feature).

Note

Azure portal, CLI, and PowerShell default to creating Gen2 VMs with Trusted Launch regardless of feature registration.
