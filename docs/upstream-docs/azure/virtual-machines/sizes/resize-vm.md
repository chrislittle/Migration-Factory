# Resize a virtual machine - Azure Virtual Machines | Microsoft Learn

**Applies to:** ✔️ Linux VMs ✔️ Windows VMs ✔️ Flexible scale sets

This article shows you how to change an existing virtual machine's [VM size](../sizes).

After you create a VM, you can scale it up or down by changing the VM size. This process works whether the VM is currently running or has already been deallocated.

In some cases, you must deallocate the VM before resizing. Deallocation may be required if the new size isn’t available on the hardware cluster currently hosting the VM. Even when deallocation isn’t required, changing the size of a running VM will cause it to restart. For this reason, resizing a VM should be considered a disruptive operation, especially for stateful workloads.

Warning

If the virtual machine is currently running, changing its size will cause it to restart.

Deallocating the VM also releases any dynamic IP addresses assigned to the VM. The OS and data disks are not affected.

If a resize operation fails, the VM model will still display the requested size, but the VM will continue running on its previous size until the resize is successfully allocated. This behavior applies to both the Azure portal, and all GET operations, as the displayed size always reflects the latest applied configuration, not the actual running size.

## Choose the right SKU

When resizing a VM, it's important to choose the right SKU based on the signals from the VM to determine whether you need more CPU, memory, or storage capacity:

- If the VM is running a CPU-intensive workload, such as a database server or a web server with high traffic, you may need to choose a SKU with more CPU cores. For more information, see [Compute optimized](/en-us/azure/virtual-machines/sizes/overview?#compute-optimized) sizes.
- If the VM is running a memory-intensive workload, such as a machine learning model or a big data application, you may need to choose a SKU with more memory. For more information, see [Memory optimized](/en-us/azure/virtual-machines/sizes/overview#memory-optimized) sizes.
- If the VM is running out of storage capacity, you may need to choose a SKU with more storage. For more information, see [Storage optimized](/en-us/azure/virtual-machines/sizes/overview#storage-optimized) sizes.
- If your VM uses Premium Storage, make sure that you choose an **s** version of the size to get Premium Storage support. For example, choose Standard\_E4**s**\_v3 instead of Standard\_E4\_v3.

For more information on choosing the right SKU, you can use the following resources:

- [Sizes for VMs in Azure](../sizes): This article lists all the VM sizes available in Azure.
- [Azure VM Selector](https://azure.microsoft.com/pricing/vm-selector/): This tool helps you find the right VM SKU based on your workload type, OS and software, and deployment region.

## Limitations

1. Resizing between VM sizes that have a local temp disk and VM sizes that have no local temp disk is supported for Linux VMs. For Windows VMs, only the following resize combinations are allowed:

    - VM (with local temp disk) -&gt; VM (with local temp disk); and
    - VM (with no local temp disk) -&gt; VM (with no local temp disk).

    For a work-around, see [How do I migrate from a VM size with local temp disk to a VM size with no local temp disk?](../azure-vms-no-temp-disk#how-do-i-migrate-my-windows-vm-from-a-size-with-local-temp-disk-to-a-vm-size-with-no-local-temp-disk---) The work-around can be used to resize a VM with no local temp disk to VM with a local temp disk. You create a snapshot of the VM with no local temp disk &gt; create a disk from the snapshot &gt; create VM from the disk with appropriate [VM size](../sizes) that supports VMs with a local temp disk.
2. You can't resize a VM size that has a SCSI-based VM to a VM size that has a remote NVMe-enabled VM.

    For a workaround, see [How can I resize a SCSI-based VM to a remote NVMe-enabled VM of a different size?](../enable-nvme-remote-faqs#how-can-i-resize-a-scsi-based-vm-to-a-remote-nvme-enabled-vm-of-a-different-size-)

## Change the VM size

Select an option for changing the VM size:

# [Portal](#tab/portal)
To change the VM size using the Azure portal:

1. Open the [Azure portal](https://portal.azure.com).
2. Type *virtual machines* in the search. Under **Services**, select **Virtual machines**.
3. In the **Virtual machines** page, select the virtual machine you want to resize.
4. In the left menu, in the **Availability + scale** section, select **size**.
5. Pick a new compatible size from the list of available sizes and then select **Resize**.

If your VM is still running and you don't see the size you want in the list, stopping the virtual machine may reveal more sizes.

# [PowerShell](#tab/powershell)
To change the size of a VM using PowerShell:

1. Set the resource group and VM name variables. Replace the values with information of the VM you want to resize.

    ```powershell
    $resourceGroup = "myResourceGroup"
    $vmName = "myVM"
    ```
2. List the VM sizes that are available on the hardware cluster where the VM is hosted.

    ```powershell
    Get-AzVMSize -ResourceGroupName $resourceGroup -VMName $vmName
    ```
3. Resize the VM to the new size.

    ```powershell
    $vm = Get-AzVM -ResourceGroupName $resourceGroup -VMName $vmName
    $vm.HardwareProfile.VmSize = "<newVMsize>"
    Update-AzVM -VM $vm -ResourceGroupName $resourceGroup
    ```

**Use PowerShell to resize a VM not in an availability set.**

This Cloud shell PowerShell script initializes the variables `$resourceGroup`, `$vm`, and `$size` with the resource group name, VM name, and desired VM size respectively. It then retrieves the VM object from Azure using the `Get-AzVM` cmdlet. The script modifies the `VmSize` property of the VM's hardware profile to the desired size. Finally, it applies these changes to the VM in Azure using the `Update-AzVM` cmdlet.

```azurepowershell
# Set variables
$resourceGroup = 'myResourceGroup'
$vmName = 'myVM'
$size = 'Standard_DS3_v2'
# Get the VM
$vm = Get-AzVM -ResourceGroupName $resourceGroup -Name $vmName
# Change the VM size
$vm.HardwareProfile.VmSize = $size
# Update the VM
Update-AzVM -ResourceGroupName $resourceGroup -VM $vm
```

As an alternative to running the script in Azure Cloud Shell, you can also execute it locally on your machine. This local version of the PowerShell script includes additional steps to import the Azure module and authenticate your Azure account.

Note

The local PowerShell may require the VM to restart to take effect.

```powershell
# Import the Azure module
Import-Module Az
# Login to your Azure account
Connect-AzAccount
# Set variables
$resourceGroup = 'myResourceGroup'
$vmName = 'myVM'
$size = 'Standard_DS3_v2'
# Select the subscription
Select-AzSubscription -SubscriptionId '<subscriptionID>'
# Get the VM
$vm = Get-AzVM -ResourceGroupName $resourceGroup -Name $vmName
# Change the VM size
$vm.HardwareProfile.VmSize = $size
# Update the VM
Update-AzVM -ResourceGroupName $resourceGroup -VM $vm
```

**Use PowerShell to resize a VM in an availability set**

If the new size for a VM in an availability set isn't available on the hardware cluster currently hosting the VM, then you need to deallocate all VMs in the availability set to resize the VM. You also might need to update the size of other VMs in the availability set after one VM has been resized. To resize a VM in an availability set, run the below script.

This script sets the variables `$resourceGroup`, `$vmName`, `$newVmSize`, and `$availabilitySetName`. It then checks if the desired VM size is available by using `Get-AzVMSize` and checking if the output contains the desired size. If the desired size isn't available, the script deallocates all VMs in the availability set, resizes them, and starts them again. If the desired size is available, the script resizes the VM.

Replace the values of `$resourceGroup`, `$vmName`, `$newVmSize`, and `$availabilitySetName` with your own.

```azurepowershell
# Set variables
$resourceGroup = "myResourceGroup"
$vmName = "myVM"
$newVmSize = "<newVmSize>"
$availabilitySetName = "<availabilitySetName>"

# Check if the desired VM size is available
$availableSizes = Get-AzVMSize `
  -ResourceGroupName $resourceGroup `
  -VMName $vmName |
  Select-Object -ExpandProperty Name
if ($availableSizes -notcontains $newVmSize) {
  # Deallocate all VMs in the availability set
  $as = Get-AzAvailabilitySet `
    -ResourceGroupName $resourceGroup `
    -Name $availabilitySetName
  $virtualMachines = $as.VirtualMachinesReferences | Get-AzResource | Get-AzVM
  $virtualMachines | Stop-AzVM -Force -NoWait

  # Resize and restart the VMs in the availability set
  $virtualMachines | Foreach-Object { $_.HardwareProfile.VmSize = $newVmSize }
  $virtualMachines | Update-AzVM
  $virtualMachines | Start-AzVM
  exit
}

# Resize the VM
$vm = Get-AzVM `
  -ResourceGroupName $resourceGroup `
  -VMName $vmName
$vm.HardwareProfile.VmSize = $newVmSize
Update-AzVM `
  -VM $vm `
  -ResourceGroupName $resourceGroup
```

# [CLI](#tab/cli)
To resize a VM, you need the latest [Azure CLI](/en-us/cli/azure/install-az-cli2) installed and you need to be signed into your Azure account using [az sign-in](/en-us/cli/azure/reference-index).

The below script checks if the desired VM size is available before resizing. If the desired size isn't available, the script exits with an error message. If the desired size is available, the script deallocates the VM, resizes it, and starts it again.

Replace the values of `resourceGroup`, `vm`, and `size` with your own.

```azurecli
 # Set variables
resourceGroup=myResourceGroup
vm=myVM
size=Standard_DS3_v2

# Check if the desired VM size is available
if ! az vm list-vm-resize-options --resource-group $resourceGroup --name $vm --query "[].name" | grep -q $size; then
    echo "The desired VM size is not available."
    exit 1
fi

# Deallocate the VM
az vm deallocate --resource-group $resourceGroup --name $vm

# Resize the VM
az vm resize --resource-group $resourceGroup --name $vm --size $size

# Start the VM
az vm start --resource-group $resourceGroup --name $vm
```

**Use Azure CLI to resize a VM in an availability set.**

The below script sets the variables `resourceGroup`, `vm`, and `size`. It then checks if the desired VM size is available by using `az vm list-vm-resize-options` and checking if the output contains the desired size. If the desired size isn't available, the script exits with an error message. If the desired size is available, the script deallocates the VM, resizes it, and starts it again.

Replace the values of `resourceGroup`, `vm`, and `size` with your own.

```azurecli
# Set variables
resourceGroup="myResourceGroup"
vmName="myVM"
newVmSize="<newVmSize>"
availabilitySetName="<availabilitySetName>"

# Check if the desired VM size is available
availableSizes=$(az vm list-vm-resize-options \
  --resource-group $resourceGroup \
  --name $vmName \
  --query "[].name" \
  --output tsv)
if [[ ! $availableSizes =~ $newVmSize ]]; then
  # Deallocate all VMs in the availability set
  vmIds=$(az vmss list-instances \
    --resource-group $resourceGroup \
    --name $availabilitySetName \
    --query "[].instanceId" \
    --output tsv)
  az vm deallocate \
    --ids $vmIds \
    --no-wait

  # Resize and restart the VMs in the availability set
  az vmss update \
    --resource-group $resourceGroup \
    --name $availabilitySetName \
    --set virtualMachineProfile.hardwareProfile.vmSize=$newVmSize
  az vmss start \
    --resource-group $resourceGroup \
    --name $availabilitySetName \
    --instance-ids $vmIds
  exit
fi

# Resize the VM
az vm resize \
  --resource-group $resourceGroup \
  --name $vmName \
  --size $newVmSize
```

# [Terraform](#tab/terraform)
To resize your VM in Terraform code, you modify the `size` parameter in the `azurerm_linux_virtual_machine` or `azurerm_windows_virtual_machine` resource blocks to the desired size and run `terraform plan -out main.tfplan` to see the VM size change that will be made. Then run `terraform apply main.tfplan` to apply the changes to resize the VM.

This Terraform example modifies the size of an existing virtual machine when you're using the state file that created the original virtual machine. For the full Terraform code, see the [Windows Terraform quickstart](../windows/quick-create-terraform).

```Terraform
resource "azurerm_windows_virtual_machine" "main" {
  name                  = "${var.prefix}-vm"
  admin_username        = "azureuser"
  admin_password        = random_password.password.result
  location              = azurerm_resource_group.rg.location
  resource_group_name   = azurerm_resource_group.rg.name
  network_interface_ids = [azurerm_network_interface.my_terraform_nic.id]
  size                  = "Standard_DS1_v2"

  os_disk {
    name                 = "myOsDisk"
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2022-datacenter-azure-edition"
    version   = "latest"
  }

  boot_diagnostics {
    storage_account_uri = azurerm_storage_account.my_storage_account.primary_blob_endpoint
  }
}
```

---
