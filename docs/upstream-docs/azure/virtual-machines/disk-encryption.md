# Server-side encryption of Azure managed disks - Azure Virtual Machines | Microsoft Learn

**Applies to:** ✔️ Linux VMs ✔️ Windows VMs ✔️ Flexible scale sets ✔️ Uniform scale sets

Most Azure managed disks are encrypted with Azure Storage encryption, which uses server-side encryption (SSE) to protect your data and to help you meet your organizational security and compliance commitments. Azure Storage encryption automatically encrypts your data stored on Azure managed disks (OS and data disks) at rest by default when persisting it to the cloud. Disks with encryption at host enabled, however, aren't encrypted through Azure Storage. For disks with encryption at host enabled, the server hosting your VM provides the encryption for your data, and that encrypted data flows into Azure Storage.

Data in Azure managed disks is encrypted transparently using 256-bit [AES encryption](https://en.wikipedia.org/wiki/Advanced_Encryption_Standard), one of the strongest block ciphers available, and is FIPS 140-2 compliant. For more information about the cryptographic modules underlying Azure managed disks, see [Cryptography API: Next Generation](/en-us/windows/desktop/seccng/cng-portal)

Azure Storage encryption doesn't impact the performance of managed disks and there's no extra cost. For more information about Azure Storage encryption, see [Azure Storage encryption](/en-us/azure/storage/common/storage-service-encryption).

Important

Temporary disks are not managed disks and are not encrypted by SSE, unless you enable encryption at host.

Azure VMs that are version 5 and above (such as Dsv5 or Dsv6) automatically encrypt their temporary disks and (if in use) their ephemeral OS disks with encryption at rest.

## Azure managed disk encryption key management

You can rely on platform-managed keys for the encryption of your managed disk, or you can manage encryption using your own keys. If you choose to manage encryption with your own keys, you can specify a *customer-managed key* to use for encrypting and decrypting all data in managed disks.

The following sections describe each of the options for key management in greater detail.

### Platform-managed keys

By default, managed disks use platform-managed encryption keys. All managed disks, snapshots, images, and data written to existing managed disks are automatically encrypted-at-rest with platform-managed keys. Platform-managed keys are managed by Microsoft.

### Customer-managed keys

You can choose to manage encryption at the level of each managed disk, with your own keys. When you specify a customer-managed key, that key is used to protect and control access to the key that encrypts your data. Customer-managed keys offer greater flexibility to manage access controls.

You must use one of the following Azure key stores to store your customer-managed keys:

- [Azure Key Vault](/en-us/azure/key-vault/general/overview) (Premium tier recommended for HSM-backed key protection)
- [Azure Key Vault Managed Hardware Security Module (HSM)](/en-us/azure/key-vault/managed-hsm/overview)

You can either import [your RSA keys](/en-us/azure/key-vault/keys/hsm-protected-keys) to your Key Vault or generate new RSA keys in Azure Key Vault.

Azure managed disks handle encryption and decryption by using envelope encryption. Managed disks encrypt data by using an [AES](https://en.wikipedia.org/wiki/Advanced_Encryption_Standard) 256-based data encryption key (DEK), and your customer-managed key protects that DEK.

The Storage service generates DEKs and encrypts those DEKs by using your RSA key.

Envelope encryption lets you rotate keys periodically without affecting your VMs. During rotation, the Storage service re-wraps DEKs with the new key version, and the underlying disk data isn't re-encrypted. Keep both the old and new key versions enabled until re-wrapping completes.

Managed disks and the Key Vault or managed HSM must be in the same Azure region, but they can be in different subscriptions. They must also be in the same Microsoft Entra tenant, unless you're using [Encrypt managed disks with cross-tenant customer-managed keys](disks-cross-tenant-customer-managed-keys).

#### Full control of your keys

You must grant access to managed disks in your Key Vault or managed HSM to use your keys for encrypting and decrypting the DEK. This allows you full control of your data and keys. You can disable your keys or revoke access to managed disks at any time. You can also audit the encryption key usage with Azure Key Vault monitoring to ensure that only managed disks or other trusted Azure services are accessing your keys.

Important

When a key is either disabled, deleted, or expired, any VMs with either OS or data disks using that key will automatically shut down. After the automated shut down, VMs won't boot until the key is enabled again, or you assign a new key.

Generally, disk I/O (read or write operations) start to fail one hour after a key is either disabled, deleted, or expired.

The following diagram shows how managed disks use Microsoft Entra ID and Azure Key Vault to make requests using the customer-managed key:

[![Diagram of managed disk and customer-managed keys workflow. An admin creates an Azure Key Vault, then creates a disk encryption set, and sets up the disk encryption set. The set is associated to a VM, which allows the disk to make use of Microsoft Entra ID to authenticate.](media/disk-encryption/customer-managed-keys-sse-managed-disks-workflow.svg)](media/disk-encryption/customer-managed-keys-sse-managed-disks-workflow.svg#lightbox)

The following list explains the diagram in more detail:

1. An Azure Key Vault administrator creates key vault resources.
2. The key vault admin either imports their RSA keys to Key Vault or generates new RSA keys in Key Vault.
3. That administrator creates an instance of Disk Encryption Set resource, specifying an Azure Key Vault ID and a key URL. Disk Encryption Set is a new resource introduced for simplifying the key management for managed disks.
4. When a disk encryption set is created, a [system-assigned managed identity](/en-us/entra/identity/managed-identities-azure-resources/overview) is created in Microsoft Entra ID and associated with the disk encryption set.
5. The Azure key vault administrator then grants the managed identity permission to perform operations in the key vault.
6. A VM user creates disks by associating them with the disk encryption set. The VM user can also enable server-side encryption with customer-managed keys for existing resources by associating them with the disk encryption set.
7. Managed disks use the managed identity to send requests to the Azure Key Vault.
8. For reading or writing data, managed disks sends requests to Azure Key Vault to encrypt (wrap) and decrypt (unwrap) the data encryption key in order to perform encryption and decryption of the data.

To revoke access to customer-managed keys, see [Azure Key Vault PowerShell](/en-us/powershell/module/az.keyvault/) and [Azure Key Vault CLI](/en-us/cli/azure/keyvault). Revoking access effectively blocks access to managed disks that rely on that key, as the encryption key is inaccessible by Azure Storage.

#### Automatic rotation of customer-managed keys

Generally, if you're using customer-managed keys, you should enable automatic key rotation to the latest key version. Automatic key rotation helps ensure your keys are secure. A disk references a key via its disk encryption set. When you enable automatic rotation for a disk encryption set, the system automatically updates all managed disks, snapshots, and images referencing the disk encryption set to use the new version of the key within one hour. To learn how to enable customer-managed keys with automatic key rotation, see [Set up Azure Key Vault and a disk encryption set with automatic key rotation](windows/disks-enable-customer-managed-keys-powershell#set-up-azure-key-vault-and-a-disk-encryption-set-with-automatic-key-rotation).

Note

Virtual Machines aren't rebooted during automatic key rotation.

If you can't enable automatic key rotation, you can use other methods to alert you before keys expire. This way, you can make sure to rotate your keys before expiration and keep business continuity. You can use either an [Azure Policy](/en-us/azure/key-vault/general/azure-policy) or [Azure Event Grid](/en-us/azure/event-grid/event-schema-key-vault) to send a notification when a key expires soon.

#### Customer-managed key restrictions

Customer-managed keys have the following restrictions. Pay special attention to identity and region requirements before deployment:

- Managed disks and your key store must be in the same region.
- Customer-managed keys depend on managed identities, so tenant moves can break key access.
- Check the following list to validate supported scenarios and feature limits.

- If this feature is enabled for a disk with incremental snapshots, it can't be disabled on that disk or its snapshots. To work around this, copy all the data to an entirely different managed disk that isn't using customer-managed keys. You can do that with either the [Azure CLI](/en-us/azure/virtual-machines/linux/disks-upload-vhd-to-managed-disk-cli#copy-a-managed-disk) or the [Azure PowerShell module](/en-us/azure/virtual-machines/windows/disks-upload-vhd-to-managed-disk-powershell#copy-a-managed-disk).
- A disk and all of its associated incremental snapshots must have the same disk encryption set.
- Only [software and HSM RSA keys](/en-us/azure/key-vault/keys/about-keys)of sizes 2,048-bit, 3,072-bit and 4,096-bit are supported, no other keys or sizes.
    - [HSM](/en-us/azure/key-vault/keys/hsm-protected-keys) keys require the **premium** tier of Azure Key vaults.
- For Ultra Disks and Premium SSD v2 disks only:
    - (Preview) User-assigned managed identities are available for Ultra Disks and Premium SSD v2 disks encrypted with customer-managed keys.
- Most resources related to your customer-managed keys (disk encryption sets, VMs, disks, and snapshots) must be in the same subscription and region.
    - Azure Key Vaults may be used from a different subscription but must be in the same region as your disk encryption set. Azure Key Vaults in different Microsoft Entra tenants are supported for managed disks. For details, see [Encrypt managed disks with cross-tenant customer-managed keys](/en-us/azure/virtual-machines/disks-cross-tenant-customer-managed-keys).
- Disks encrypted with customer-managed keys can only move to another resource group if the VM they're attached to is deallocated.
- Disks, snapshots, and images encrypted with customer-managed keys can't be moved between subscriptions.
- Managed disks currently or previously encrypted using Azure Disk Encryption can't be encrypted using customer-managed keys.
- Can only create up to 5000 disk encryption sets per region per subscription.
- For information about using customer-managed keys with shared image galleries, see [Preview: Use customer-managed keys for encrypting images](/en-us/azure/virtual-machines/image-version-encryption).

#### Supported regions for customer-managed keys

Customer-managed keys are available in all regions that managed disks are available.

Important

Customer-managed keys rely on managed identities for Azure resources, a feature of Microsoft Entra ID. When you configure customer-managed keys, the system automatically assigns a managed identity to your resources. If you move the subscription, resource group, or managed disk from one Microsoft Entra directory to another, the managed identity associated with managed disks isn't transferred to the new tenant, so customer-managed keys might stop working. For more information, see [Transferring a subscription between Microsoft Entra directories](/en-us/azure/active-directory/managed-identities-azure-resources/known-issues#transferring-a-subscription-between-azure-ad-directories).

To enable customer-managed keys for managed disks, see the following articles covering how to enable it with either the [Azure PowerShell module](windows/disks-enable-customer-managed-keys-powershell), the [Azure CLI](linux/disks-enable-customer-managed-keys-cli), or the [Azure portal](/en-us/azure/virtual-machines/disks-enable-customer-managed-keys-portal).

See [Create a managed disk from a snapshot with CLI](scripts/create-managed-disk-from-snapshot#disks-with-customer-managed-keys) for a code sample.

## Encryption at host - End-to-end encryption for your VM data

When you enable encryption at host, that encryption starts on the VM host itself, the Azure server that your VM is allocated to. The data for your temporary disk and OS/data disk caches are stored on that VM host. After enabling encryption at host, all this data is encrypted at rest and flows encrypted to the Storage service, where it's persisted. Essentially, encryption at host encrypts your data from end-to-end. Encryption at host doesn't use your VM's CPU and doesn't impact your VM's performance.

Temporary disks and ephemeral OS disks are encrypted at rest with platform-managed keys when you enable end-to-end encryption. The OS and data disk caches are encrypted at rest with either customer-managed or platform-managed keys, depending on the selected disk encryption type. For example, if a disk is encrypted with customer-managed keys, then the cache for the disk is encrypted with customer-managed keys, and if a disk is encrypted with platform-managed keys then the cache for the disk is encrypted with platform-managed keys.

### Encryption at host restrictions

Before you enable encryption at host for production workloads, review the following restrictions:

- VM size support varies by region and generation.
- Encryption behavior differs for temporary disks, ephemeral OS disks, and caches.
- Check workload prerequisites before applying at scale.

- Can't be enabled on virtual machines (VMs) or virtual machine scale sets that currently or ever had Azure Disk Encryption enabled.
- Azure Disk Encryption can't be enabled on disks that have encryption at host enabled.
- The encryption can be enabled on existing virtual machine scale sets. However, only new VMs created after enabling the encryption are automatically encrypted.
- Existing VMs must be deallocated and reallocated in order to be encrypted.

The following restrictions only apply to Ultra Disks and Premium SSD v2:

- Disks using a 512e sector size need to have been created after 5/13/2023.
    - If your disk was created before this date, [snapshot your disk](/en-us/azure/virtual-machines/disks-incremental-snapshots), and create a new disk using the snapshot.

#### Supported VM sizes

The complete list of supported VM sizes can be pulled programmatically. To learn how to retrieve them programmatically, refer to the finding supported VM sizes section of either the [Azure PowerShell module](windows/disks-enable-host-based-encryption-powershell#finding-supported-vm-sizes) or [Azure CLI](linux/disks-enable-host-based-encryption-cli#finding-supported-vm-sizes) articles.

To enable end-to-end encryption by using encryption at host, see the following articles that cover how to enable it by using either the [Azure PowerShell module](windows/disks-enable-host-based-encryption-powershell), the [Azure CLI](linux/disks-enable-host-based-encryption-cli), or the [Azure portal](disks-enable-host-based-encryption-portal).

## Double encryption at rest

High security sensitive customers who are concerned of the risk associated with any particular encryption algorithm, implementation, or key being compromised can now opt for extra layer of encryption using a different encryption algorithm/mode at the infrastructure layer using platform managed encryption keys. This new layer can be applied to persisted OS and data disks, snapshots, and images, all of which will be encrypted at rest with double encryption.

### Double encryption restrictions

Double encryption at rest isn't currently supported with either Ultra Disks or Premium SSD v2 disks.

To enable double encryption at rest for managed disks, see [Enable double encryption at rest for managed disks](disks-enable-double-encryption-at-rest-portal).

## Encryption at host versus Azure disk encryption

[Azure Disk Encryption](disk-encryption-overview) leverages either the [DM-Crypt](https://en.wikipedia.org/wiki/Dm-crypt) feature of Linux or the [BitLocker](/en-us/windows/security/information-protection/bitlocker/bitlocker-overview) feature of Windows to encrypt managed disks with customer-managed keys within the guest VM. Server-side encryption with encryption at host improves on ADE. With encryption at host, data for your temporary disk and OS/data disk caches are stored on that VM host. After enabling encryption at host, all this data is encrypted at rest and flows encrypted to the Storage service, where it's persisted. Essentially, encryption at host encrypts your data from end-to-end. Encryption at host doesn't use your VM's CPU and doesn't impact your VM's performance.
