# The SKUs of the RedHat RHEL marketplace offer (2026-11-11)

RHEL-EUS-SKU-LIST-1. A read of Azure's image list, no cost:

```
az vm image list --offer RHEL --all -p RedHat -l centralus -o json
```

`--offer` and `--publisher` take a partial name, so the list was filtered in
PowerShell to publisher `RedHat` and offer `RHEL` exactly (no `--query`
filter: CLAUDE.md). 2281 images came back; 50 SKUs are `RedHat:RHEL`. Every
image is x64.

Microsoft, Red Hat Update Infrastructure: "Images connected to EUS
repositories contain a minor version number in the SKU". The middle column is
the major and minor release of the image versions of each SKU, which Azure
gives as `<major>.<minor>.<date>`. The last column is the release
`Get-VmfImageRelease` must read from the SKU: the one minor release where the
SKU has one, the major only where it is an LVM SKU (non-EUS, several minor
releases). `tests/unit/RhelImageSkus.Tests.ps1` reads this table and holds
the reader to every row.

Spellings seen: `9_4`, `10_2-gen2`, `94_gen2`, `94-gen2` and a three-digit
`810-gen2`, `100-gen2`, `101-gen2` (major 10, minor 0 and 1 - not major 1);
the LVM SKUs `9-lvm`, `9-lvm-gen2`, `7-LVM` and `7lvm-gen2` (no hyphen).
Before this list, the reader read `100-gen2` as 1.00, `101-gen2` as 1.01 and
`7lvm-gen2` as no release.

| SKU | Image versions | Release read |
|---|---|---|
| `10_0` | 10.0 | 10.0 |
| `10_1` | 10.1 | 10.1 |
| `10_2` | 10.2 | 10.2 |
| `10_2-gen2` | 10.2 | 10.2 |
| `10-lvm` | 10.0, 10.1, 10.2 | 10 |
| `10-lvm-gen2` | 10.0, 10.1, 10.2 | 10 |
| `100-gen2` | 10.0 | 10.0 |
| `101-gen2` | 10.1 | 10.1 |
| `7_9` | 7.9 | 7.9 |
| `7-LVM` | 7.4, 7.5, 7.6, 7.7, 7.8, 7.9 | 7 |
| `79-gen2` | 7.9 | 7.9 |
| `7lvm-gen2` | 7.4, 7.5, 7.6, 7.7, 7.8, 7.9 | 7 |
| `8_10` | 8.10 | 8.10 |
| `8_3` | 8.3 | 8.3 |
| `8_4` | 8.4 | 8.4 |
| `8_5` | 8.5 | 8.5 |
| `8_6` | 8.6 | 8.6 |
| `8_7` | 8.7 | 8.7 |
| `8_8` | 8.8 | 8.8 |
| `8_9` | 8.9 | 8.9 |
| `8-LVM` | 8.0, 8.1, 8.10, 8.2, 8.3, 8.4, 8.5, 8.6, 8.7, 8.8, 8.9 | 8 |
| `8-lvm-gen2` | 8.0, 8.1, 8.10, 8.2, 8.3, 8.4, 8.5, 8.6, 8.7, 8.8, 8.9 | 8 |
| `810-gen2` | 8.10 | 8.10 |
| `83-gen2` | 8.3 | 8.3 |
| `84-gen2` | 8.4 | 8.4 |
| `85-gen2` | 8.5 | 8.5 |
| `86-gen2` | 8.6 | 8.6 |
| `87-gen2` | 8.7 | 8.7 |
| `88-gen2` | 8.8 | 8.8 |
| `89-gen2` | 8.9 | 8.9 |
| `9_0` | 9.0 | 9.0 |
| `9_1` | 9.1 | 9.1 |
| `9_2` | 9.2 | 9.2 |
| `9_3` | 9.3 | 9.3 |
| `9_4` | 9.4 | 9.4 |
| `9_5` | 9.5 | 9.5 |
| `9_6` | 9.6 | 9.6 |
| `9_7` | 9.7 | 9.7 |
| `9_8` | 9.8 | 9.8 |
| `9_8-gen2` | 9.8 | 9.8 |
| `9-lvm` | 9.0, 9.1, 9.2, 9.3, 9.4, 9.5, 9.6, 9.7, 9.8 | 9 |
| `9-lvm-gen2` | 9.0, 9.1, 9.2, 9.3, 9.4, 9.5, 9.6, 9.7, 9.8 | 9 |
| `90-gen2` | 9.0 | 9.0 |
| `91-gen2` | 9.1 | 9.1 |
| `92-gen2` | 9.2 | 9.2 |
| `93-gen2` | 9.3 | 9.3 |
| `94_gen2` | 9.4 | 9.4 |
| `95_gen2` | 9.5 | 9.5 |
| `96-gen2` | 9.6 | 9.6 |
| `97-gen2` | 9.7 | 9.7 |
