# Upgrade Basic Public IP Address to Standard SKU in Azure | Microsoft Learn

Important

On September 30, 2025, Basic SKU public IPs were retired. For more information, see the [official announcement](https://azure.microsoft.com/updates/upgrade-to-standard-sku-public-ip-addresses-in-azure-by-30-september-2025-basic-sku-will-be-retired/). If you are currently using Basic SKU public IPs, make sure to upgrade to Standard SKU public IPs as soon as possible. This article will help guide you through the upgrade process.

This article explains how to upgrade your Basic SKU public IPs to Standard SKU. Upgrading to Standard public IPs ensures continued support after retirement and provides enhanced security and availability for your workloads.

## Steps to complete the upgrade

We recommend the following approach to upgrade to Standard SKU public IP addresses.

1. Learn about some of the key differences between Basic SKU public IP and Standard SKU public IP.
2. Identify the [Basic SKU public IP](public-ip-upgrade-portal#upgrade-public-ip-address) in your organization that requires upgrade.
3. Determine if you would need [Zone Redundancy](public-ip-addresses#availability-zone).

    a. If you need a zone redundant public IP address, create a new Standard SKU public IP address using [Portal](create-public-ip-portal), [PowerShell](create-public-ip-powershell), [CLI](create-public-ip-cli), or [ARM template](create-public-ip-template).

    b. If you don't need a zone redundant public IP address, use the following upgrade options.
4. Determine if you need a regional or [global tier](../../load-balancer/cross-region-overview) public IP Address.

    1. If the public IP address aligns with a standard load balancer, the IP address *must align* with the load balancer tier.
5. Create a migration plan for planned downtime.
6. Depending on the resource associated with your Basic SKU public IP addresses, perform the upgrade based on the following table:

| Resource using Basic SKU public IP addresses | Decision path |
| --- | --- |
| Virtual Machine | Use scripts or manually detach and upgrade public IPs. For standalone virtual machines, you can use the [upgrade script](public-ip-upgrade-vm) or for virtual machines in an availability set use [this script](public-ip-upgrade-availability-set). |
| Virtual Machine Scale Sets | [Replace basic SKU instance public IP addresses](/en-us/azure/virtual-machine-scale-sets/virtual-machine-scale-sets-networking#public-ipv4-per-virtual-machine) with new standard SKU. |
| Load Balancer (Basic SKU) | New Load Balancer SKU required. Use the upgrade script [Upgrade Basic Load Balancer to Standard SKU](../../load-balancer/upgrade-basic-standard-with-powershell) to upgrade to Standard Load Balancer. |
| VPN Gateway (using Basic IPs) | VPN Gateway migration is required. All non-AZ SKUs become AZ SKUs. Follow the [VPN Gateway migration guidance](../../vpn-gateway/basic-public-ip-migrate-howto) to upgrade to Standard SKU public IPs. For the latest migration timeline, please see [this page](/en-us/azure/vpn-gateway/whats-new#upcoming-projected-changes). |
| ExpressRoute gateway (using Basic SKU public IP addresses) | Use the [ExpressRoute gateway migration experience](../../expressroute/gateway-migration#enable-zone-redundancy) to migrate to a Standard SKU public IP address. For zone redundancy, select an availability zone-enabled gateway SKU during migration. Azure automatically assigns and manages the zone-redundant public IP address for the migrated gateway. |
| Application Gateway (v1 SKU) | Migrate to Application Gateway v2. Microsoft retired Application Gateway v1 on April 28, 2026. For guidance, see [Migrate Azure Application Gateway and Web Application Firewall from v1 to v2](../../application-gateway/migrate-v1-v2). |
| Azure Databricks (using Basic IPs) | For ephemeral workloads, Standard SKU public IP addresses are automatically deployed as virtual machines (VMs) cycle out through regular usage attrition with new VMs. For long running workloads, we recommended manually [restarting the compute resources](/en-us/azure/databricks/compute/clusters-manage#restart) which replaces existing Basic IPs with Standard IPs. |

Note

If you have a virtual machine scale set (uniform model) with public IP configurations per instance, note these aren't Public IP resources and as such can't be upgraded; a new public IP address is required. You can use the SKU property to specify that Standard IP configurations are required for each VMSS instance as shown [here](/en-us/azure/virtual-machine-scale-sets/virtual-machine-scale-sets-networking#public-ipv4-per-virtual-machine).

## Basic SKU vs. Standard SKU

This section lists out some key differences between these two SKUs.

| Aspect | Standard SKU public IP | Basic SKU public IP |
| --- | --- | --- |
| **Allocation method** | Static. | For IPv4: Dynamic or Static; For IPv6: Dynamic. |
| **Security** | Uses *Secure by default* model closed to inbound traffic when used as a frontend. To allow traffic, a [network security group](../network-security-groups-overview#network-security-groups) is required (for example, on the NIC of a virtual machine with a Standard SKU public IP attached). | Open by default. Network security groups are recommended but optional for restricting inbound or outbound traffic. |
| **[Availability zones](/en-us/azure/reliability/availability-zones-overview)** | Supported. Standard IPs can be non-zonal, zonal, or zone-redundant. Zone redundant IPs can only be created in [regions where availability zones](/en-us/azure/reliability/availability-zones-region-support) are live. IPs created before availability zones aren't zone redundant. | Not supported. |
| **[Routing preference](routing-preference-overview)** | Supported to enable more granular control of how traffic is routed between Azure and the Internet. | Not supported. |
| **Global tier** | Supported via [cross-region load balancers](../../load-balancer/cross-region-overview). | Not supported. |
| **[Standard Load Balancer Support](../../load-balancer/skus)** | Both IPv4 and IPv6 are supported. | Not supported. |
| **[NAT Gateway Support](../nat-gateway/nat-overview)** | IPv4 is supported. | Not supported. |
| **[Azure Firewall Support](../nat-gateway/nat-overview)** | IPv4 is supported. | Not supported. |

## Upgrade disassociated public IPs using Portal, PowerShell, or Azure CLI

Use the Azure portal, Azure PowerShell, or Azure CLI to help upgrade from Basic to Standard SKU.

- [Upgrade a disassociated public IP address - Azure portal](public-ip-upgrade-portal)
- [Upgrade a disassociated public IP address - Azure PowerShell](public-ip-upgrade-powershell)
- [Upgrade a disassociated public IP address - Azure CLI](public-ip-upgrade-cli)

## FAQ

### Will the Basic SKU public IP retirement impact Cloud Services Extended Support (CSES) deployments?

No, this retirement won't impact your existing or new deployments on CSES. This means that you can still create (via non-Azure portal methods; for example, Azure CLI, PowerShell, etc.) and use Basic SKU public IPs for CSES deployments. However, we advise using Standard SKU on Azure Resource Manager native resources that don't depend on CSES when possible, because Standard has more advantages than Basic.

### What will happen to my Basic public IP resource post-retirement (September 30, 2025)?

Basic public IPs will remain operational after September 30, 2025, giving users more time to transition to Standard SKU. Customers who choose to continue using Basic public IPs after retirement date accept the risks and acknowledge that the service is unsupported and not covered by SLA guarantees.
