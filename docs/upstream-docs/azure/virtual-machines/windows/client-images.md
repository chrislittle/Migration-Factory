# Use Windows client images in Azure - Azure Virtual Machines | Microsoft Learn

**Applies to:** ✔️ Windows VMs

You can use Windows 10 Enterprise (x64) or Windows 11 Enterprise (x64) in Azure for dev/test scenarios provided you have an appropriate Visual Studio (formerly MSDN) subscription.

To run Windows 10 or 11 in a production environment see, [How to deploy Windows 10 or 11 on Azure with Multitenant Hosting Rights](windows-desktop-multitenant-hosting-deployment).

## Subscription eligibility

Active Visual Studio subscribers (people who have acquired a Visual Studio subscription license) can use Windows client images for development and testing purposes. Windows client images can be used on your own hardware or on Azure virtual machines.

Certain Windows client images are available from the Azure Marketplace. Visual Studio subscribers within any type of offer can also [prepare and create](prepare-for-upload-vhd-image) 64-bit Windows 10 or 11 images and then [upload to Azure](upload-generalized-managed).

## Eligible offers and client images

The following table details the offer IDs that are eligible to deploy Windows client images through the Azure Marketplace. The Windows client images are only visible to the following offers.

Note

Image offers are under **Windows Client** in the Azure Marketplace. Use **Windows Client** when searching for client images available to Visual Studio subscribers. If you need to purchase a Visual Studio subscription, see the various options at [Buy Visual Studio](https://visualstudio.microsoft.com/vs/pricing/?tab=business)

| Offer Name | Offer Number | Available client images |
| --- | --- | --- |
| [Pay-As-You-Go Dev/Test](https://azure.microsoft.com/offers/ms-azr-0023p/) | 0023P | Windows 10 Enterprise N (x64)  Windows 11 Enterprise (x64) |
| [Visual Studio Enterprise (MPN) subscribers](https://azure.microsoft.com/offers/ms-azr-0029p/) | 0029P | Windows 10 Enterprise N (x64)  Windows 11 Enterprise (x64) |
| [Visual Studio Professional subscribers](https://azure.microsoft.com/offers/ms-azr-0059p/) | 0059P | Windows 10 Enterprise N (x64)  Windows 11 Enterprise (x64) |
| [Visual Studio Test Professional subscribers](https://azure.microsoft.com/offers/ms-azr-0060p/) | 0060P | Windows 10 Enterprise N (x64)  Windows 11 Enterprise (x64) |
| [Visual Studio Enterprise subscribers](https://azure.microsoft.com/offers/ms-azr-0063p/) | 0063P | Windows 10 Enterprise N (x64)  Windows 11 Enterprise (x64) |
| [Visual Studio Enterprise (BizSpark) subscribers](https://azure.microsoft.com/offers/ms-azr-0064p/) | 0064P | Windows 10 Enterprise N (x64)  Windows 11 Enterprise (x64) |
| [Enterprise Dev/Test](https://azure.microsoft.com/offers/ms-azr-0148p/) | 0148P | Windows 10 Enterprise N (x64)  Windows 11 Enterprise (x64) |

For more information, see [Understand Microsoft offer types](/en-us/azure/cost-management-billing/costs/understand-cost-mgt-data#supported-microsoft-azure-offers)

## Check your Azure subscription

If you do not know your offer ID, you can obtain it through the Azure portal.

- On the *Subscriptions* window: ![Offer ID details from the Azure portal](media/client-images/offer-id-azure-portal.png)
- Or, click **Billing** and then click your subscription ID. The offer ID appears in the *Billing* window.
