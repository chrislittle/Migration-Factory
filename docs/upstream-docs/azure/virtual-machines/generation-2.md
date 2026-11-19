# Azure support for Generation 2 VMs - Azure Virtual Machines | Microsoft Learn

**Applies to:** ✔️ Linux VMs ✔️ Windows VMs ✔️ Flexible scale sets ✔️ Uniform scale sets

Support for Generation 2 virtual machines (VMs) is now available on Azure. You can also upgrade existing Generation 1 virtual machines to Generation 2 with Trusted launch. Review the considerations on this page and the [upgrade guidance](trusted-launch-existing-vm-gen-1) before choosing or upgrading a generation.

Generation 2 VMs support key features that aren't supported in Generation 1 VMs. These features include increased memory, Intel Software Guard Extensions (Intel SGX), and virtualized persistent memory (vPMEM). Generation 2 VMs running on-premises, have some features that aren't supported in Azure yet. For more information, see the Features and capabilities section.

Generation 2 VMs use the new UEFI-based boot architecture rather than the BIOS-based architecture used by Generation 1 VMs. Compared to Generation 1 VMs, Generation 2 VMs might have improved boot and installation times. For an overview of Generation 2 VMs and some of the differences between Generation 1 and Generation 2, see [Should I create a Generation 1 or 2 virtual machine in Hyper-V?](/en-us/windows-server/virtualization/hyper-v/plan/should-i-create-a-generation-1-or-2-virtual-machine-in-hyper-v).

## Generation 2 VM sizes

Azure now offers Generation 2 support for the following selected VM series:

| Type | Generation 2 supported size families | Not supported size families |
| --- | --- | --- |
| [General purpose](sizes/overview#general-purpose) | [B-family](sizes/general-purpose/b-family), [D-family](sizes/general-purpose/d-family) | [A-family](sizes/general-purpose/a-family) |
| [Compute optimized](sizes/overview#compute-optimized) | [F-family](sizes/compute-optimized/f-family), [Fx-family](sizes/compute-optimized/fx-family) |  |
| [Memory optimized](sizes/overview#memory-optimized) | [E-family](sizes/memory-optimized/e-family), [Eb-family](sizes/memory-optimized/eb-family), [M-family](sizes/memory-optimized/m-family) |  |
| [Storage optimized](sizes/overview#storage-optimized) | [L-family](sizes/storage-optimized/l-family) |  |
| [GPU](sizes/overview#gpu-accelerated) | [NC-family](sizes/gpu-accelerated/nc-family), [ND-family](sizes/gpu-accelerated/nv-family), [NV-family](sizes/gpu-accelerated/nv-family) | [NC-series](nc-series), [NV-series](nv-series) |
| [High Performance Compute](sizes/overview#high-performance-compute) | [HBv2-series](sizes/high-performance-compute/hbv2-series-overview), [HBv3-series](sizes/high-performance-compute/hbv3-series-overview), [HBv4-series](sizes/high-performance-compute/hbv4-series-overview), [HC-series](sizes/high-performance-compute/hc-series-overview), [HX-series](sizes/high-performance-compute/hx-series-overview) |  |

^1^ Mv2-series, DC-series, NDv2-series, Msv2 and Mdsv2-series Medium Memory do not support Generation 1 VM images and only support a subset of Generation 2 images. Please see [Mv2-series documentation](mv2-series), [ND A100 v4-series](nda100-v4-series), [NDv2-series](ndv2-series), and [Msv2 and Mdsv2 Medium Memory Series](msv2-mdsv2-series) for details.

## Generation 2 VM images in Azure Marketplace

Generation 2 VMs support the following Marketplace images:

- Windows Server 2025, 2022, 2019, 2016, 2012 R2, 2012
- Windows 11 Pro, Windows 11 Enterprise
- Windows 10 Pro, Windows 10 Enterprise
- SUSE Linux Enterprise Server 15 SP3, SP2
- SUSE Linux Enterprise Server 12 SP4
- Ubuntu Server 22.04 LTS, 20.04 LTS, 18.04 LTS, 16.04 LTS
- RHEL 9,5, 9.4, 9.3, 9.2, 9.1, 9.0, 8.10, 8.9, 8.8, 8.7, 8.6, 8.5, 8.4, 8.3, 8.2, 8.1, 8.0, 7.9, 7.8, 7.7, 7.6, 7.5, 7.4, 7.0
- Cent OS 8.4, 8.3, 8.2, 8.1, 8.0, 7.7, 7.6, 7.5, 7.4
- Oracle Linux 9.3, 9.2, 9.1, 9.0, 8.9, 8.8, 8.7, 8.6, 8.5, 8.4, 8.3, 8.2, 8.1, 7.9, 7.9, 7.8, 7.7

Note

Specific Virtual machine sizes like Mv2-Series, DC-series, ND A100 v4-series, NDv2-series, Msv2 and Mdsv2-series may only support a subset of these images - please look at the relevant virtual machine size documentation for complete details.

## On-premises vs. Azure Generation 2 VMs

Azure doesn't currently support some of the features that on-premises Hyper-V supports for Generation 2 VMs.

| Generation 2 feature | On-premises Hyper-V | Azure |
| --- | --- | --- |
| Secure boot | ✔️ | With [trusted launch](trusted-launch) |
| Shielded VM | ✔️ | ❌ |
| vTPM | ✔️ | With [trusted launch](trusted-launch) |
| Virtualization-based security (VBS) | ✔️ | ✔️ |
| VHDX format | ✔️ | ❌ |

For more information, see [Trusted launch](trusted-launch).

## Features and capabilities

### Generation 1 vs. Generation 2 features

| Feature | Generation 1 | Generation 2 |
| --- | --- | --- |
| Boot | PCAT | UEFI |
| Disk controllers | IDE | SCSI |
| VM sizes | All VM sizes | See available sizes |

### Generation 1 vs. Generation 2 capabilities

| Capability | Generation 1 | Generation 2 |
| --- | --- | --- |
| OS disk &gt; 2 TB | ❌ | ✔️ |
| Custom disk/image/swap OS | ✔️ | ✔️ |
| Virtual machine scale set support | ✔️ | ✔️ |
| Azure Site Recovery | ✔️ | ✔️ |
| Backup/restore | ✔️ | ✔️ |
| Azure Compute Gallery | ✔️ | ✔️ |
| [Azure disk encryption](disk-encryption-overview) | ✔️ | ✔️ |
| [Server-side encryption](disk-encryption) | ✔️ | ✔️ |

## Creating a Generation 2 VM

### Azure Resource Manager Template

To create a simple Windows Generation 2 VM, see [Create a Windows virtual machine from a Resource Manager template](windows/ps-template) To create a simple Linux Generation 2 VM, see [How to create a Linux virtual machine with Azure Resource Manager templates](linux/create-ssh-secured-vm-from-template)

### Marketplace image

In the Azure portal or Azure CLI, you can create Generation 2 VMs from a Marketplace image that supports UEFI boot.

#### Azure portal

Below are the steps to create a Generation 2 (Gen2) VM in Azure portal.

1. Sign in to the [Azure portal](https://portal.azure.com).
2. Search for **Virtual Machines**
3. Under **Services**, select **Virtual machines**.
4. In the **Virtual machines** page, select **Add**, and then select **Virtual machine**.
5. Under **Project details**, make sure the correct subscription is selected.
6. Under **Resource group**, select **Create new** and type a name for your resource group or select an existing resource group from the dropdown.
7. Under **Instance details**, type a name for the virtual machine name and choose a region
8. Under **Image**, select a Generation 2 image from the **Marketplace images to get started**
    Tip

    If you don't see the Generation 2 version of the image you want in the drop-down, select **See all images** and then change the **Image Type** filter to **Gen 2**.
9. Select a VM size that supports Generation 2. See a list of supported sizes.
10. Fill in the **Administrator account** information and then **Inbound port rules**
11. At the bottom of the page, select **Review + Create**
12. On the **Create a virtual machine** page, you can see the details about the VM you are about to deploy. Once validation shows as passed, select **Create**.

#### PowerShell

You can also use PowerShell to create a VM by directly referencing the Generation 1 or Generation 2 SKU.

For example, use the following PowerShell cmdlet to get a list of the SKUs in the `WindowsServer` offer.

```powershell
Get-AzVMImageSku -Location westus2 -PublisherName MicrosoftWindowsServer -Offer WindowsServer
```

If you're creating a VM with Windows Server 2019 as the OS, then you can select a Generation 2 (UEFI) image which looks like this:

```powershell
2019-datacenter-gensecond
```

If you're creating a VM with Windows 10 as the OS, then you can select a Generation 2 (UEFI) image which looks like this:

```powershell
20H2-PRO-G2
```

See the Features and capabilities section for a current list of supported Marketplace images.

#### Azure CLI

Alternatively, you can use the Azure CLI to see any available Generation 2 images, listed by **Publisher**.

```azurecli
az vm image list --publisher Canonical --sku gen2 --output table --all
```

### Managed image or managed disk

You can create a Generation 2 VM from a managed image or managed disk in the same way you would create a Generation 1 VM.

### Virtual machine scale sets

You can also create Generation 2 VMs by using virtual machine scale sets. In the Azure CLI, use Azure scale sets to create Generation 2 VMs.

Note

Alternatively, you can upgrade an existing Generation 1 VM to Generation 2 with Trusted launch. For more information, see [Upgrade existing Gen1 VMs to Gen2-Trusted launch](trusted-launch-existing-vm-gen-1).

## Frequently asked questions

- **Are Generation 2 VMs available in all Azure regions?** Yes. But not all generation 2 VM sizes are available in every region. The availability of the Generation 2 VM depends on the availability of the VM size.
- **Is there a price difference between Generation 1 and Generation 2 VMs?** No.
- **I have a .vhd file from my on-premises Generation 2 VM. Can I use that .vhd file to create a Generation 2 VM in Azure?** Yes, you can bring your Generation 2 .vhd file to Azure and use that to create a Generation 2 VM. Use the following steps to do so:

    1. Upload the .vhd to a storage account in the same region where you'd like to create your VM.
    2. Create a managed disk from the .vhd file. Set the Hyper-V Generation property to V2. The following PowerShell commands set Hyper-V Generation property when creating managed disk.

        ```powershell
        $sourceUri = 'https://xyzstorage.blob.core.windows.net/vhd/abcd.vhd'. #<Provide location to your uploaded .vhd file>
        $osDiskName = 'gen2Diskfrmgenvhd'  #<Provide a name for your disk>
        $diskconfig = New-AzDiskConfig -Location '<location>' -DiskSizeGB 127 -AccountType Standard_LRS -OsType Windows -HyperVGeneration "V2" -SourceUri $sourceUri -CreateOption 'Import'
        New-AzDisk -DiskName $osDiskName -ResourceGroupName '<Your Resource Group>' -Disk $diskconfig
        ```
    3. Once the disk is available, create a VM by attaching this disk. The VM created will be a Generation 2 VM. When the Generation 2 VM is created, you can optionally generalize the image of this VM. By generalizing the image, you can use it to create multiple VMs.
- **How do I increase the OS disk size?**

    OS disks larger than 2 TiB are new to Generation 2 VMs. By default, OS disks are smaller than 2 TiB for Generation 2 VMs. You can increase the disk size up to a recommended maximum of 4 TiB. Use the Azure CLI or the Azure portal to increase the OS disk size. For information about how to expand disks programmatically, see **Resize a disk** for [Windows](windows/expand-os-disk) or [Linux](linux/resize-os-disk-gpt-partition).

    To increase the OS disk size from the Azure portal:

    1. In the Azure portal, go to the VM properties page.
    2. To shut down and deallocate the VM, select the **Stop** button.
    3. In the **Disks** section, select the OS disk you want to increase.
    4. In the **Disks** section, select **Configuration**, and update the **Size** to the value you want.
    5. Go back to the VM properties page and **Start** the VM.

    You might see a warning for OS disks larger than 2 TiB. The warning doesn't apply to Generation 2 VMs. However, OS disk sizes larger than 4 TiB are not supported.
- **Do Generation 2 VMs support accelerated networking?** Yes. For more information, see [Create a VM with accelerated networking](/en-us/azure/virtual-network/create-vm-accelerated-networking-cli).
- **Do Generation 2 VMs support Secure Boot or vTPM in Azure?** Both vTPM and Secure Boot are features of trusted launch for Generation 2 VMs. For more information, see [Trusted launch](trusted-launch).
- **Is VHDX supported on Generation 2?** No, Generation 2 VMs on Azure support only VHD.
- **Do Generation 2 VMs support Azure Ultra Disk Storage?** Yes.
- **Can I migrate a VM from Generation 1 to Generation 2?** Azure Virtual Machines supports upgrading existing Generation 1 VMs to Generation 2 by upgrading to the Trusted launch security type. See [Upgrade existing Gen1 VMs to Gen2-Trusted launch](trusted-launch-existing-vm-gen-1) for steps and prerequisites.
- **Why is my VM size not enabled in the size selector when I try to create a Generation 2 VM?**

    This may be solved by doing the following:

    1. Verify that the **VM Generation** property is set to **Gen 2**.
    2. Verify you are searching for a VM size which supports Generation 2 VMs.
