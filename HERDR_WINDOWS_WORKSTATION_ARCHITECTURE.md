# Herdr Windows Workstation Architecture

Last updated: August 16, 2026

## Purpose

Provide an always-on x86-64 workstation on the home Ethernet network for persistent Herdr and AI CLI sessions, native Microsoft Excel COM automation, and remote work while traveling.

The goal is a dependable off-the-shelf system, not a local-model workstation or a custom PC build.

## Final architecture

~~~
Laptop / Surface / phone while local or traveling
|-- Tailscale + SSH/Mosh --> Ubuntu Hyper-V VM --> Herdr and persistent CLI sessions
|-- Tailscale + RDP ------> Windows 11 Pro host --> native Excel and COM automation
`-- Tailscale + browser --> GL.iNet Comet PoE KVM
                              |-- HDMI + USB --> MS-A2 BIOS/UEFI/console
                              `-- Fingerbot --> physical power button

MINISFORUM MS-A2
`-- Windows 11 Pro on bare metal
    |-- Native desktop Excel in an interactive logged-in session
    |-- Hyper-V Ubuntu 24.04 LTS VM (automatic start before user logon)
    |   |-- Tailscale node: herdr-ubuntu
    |   |-- OpenSSH + Mosh + native systemd
    |   `-- Herdr, repositories and AMD64 CLI tooling
    |-- Tailscale node: herdr-win
    |-- Restricted SMB share: \\herdr-win\HerdrExchange
    `-- 2 TB factory NVMe SSD

Recovery layers
|-- Git remotes for repositories
|-- Backblaze for supported user data
|-- Veeam entire-computer images on a 20 TB external drive
`-- Veeam recovery ISO stored on Comet eMMC, laptop/cloud and backup drive
~~~

## Purchase and selection record

Status meanings:

- **Ordered** means the order was explicitly confirmed in this purchasing session.
- **Selected** means the exact product was validated, but shipment or order confirmation was not explicitly recorded.
- **Deferred** means intentionally postponed.
- **Existing** means no purchase is required.

| Status | Component | Exact selection | Price recorded | Link / identifier |
|---|---|---|---:|---|
| **Ordered** | Workstation | MINISFORUM MS-A2, Ryzen 9 9955HX, 64 GB DDR5, 2 TB SSD | $1,719.00 | [Amazon](https://www.amazon.com/dp/B0FZQYZ7JQ), ASIN B0FZQYZ7JQ |
| **Ordered** | Windows contingency | Microsoft Windows 11 Pro, 64-bit, International English, FPP retail USB | $149.99 | [Amazon](https://www.amazon.com/dp/B09X11M88J), ASIN B09X11M88J |
| **Ordered** | Remote KVM | GL.iNet Comet PoE GL-RM1PE, 32 GB eMMC | $115.99 | [Amazon](https://www.amazon.com/dp/B0FDQJ1V7J) |
| **Ordered** | Remote power control | GL.iNet Fingerbot FGB-01 | $29.99 | [Amazon](https://www.amazon.com/dp/B0GL6V276Z) |
| **Ordered** | UPS | CyberPower CP1500PFCLCD, 1500 VA / 1000 W pure sine wave | $239.95 | [Amazon](https://www.amazon.com/dp/B00429N19W) |
| **Ordered** | Local input | Logitech MK270 wireless keyboard and mouse with USB receiver | $22.99 | [Amazon](https://www.amazon.com/dp/B079JLY5M5) |
| **Existing** | Setup monitor | Borrow an existing Dell 32-inch monitor or the son's monitor | $0 | No purchase required |
| **Deferred** | Onsite backup | One approximately 20 TB external USB desktop hard drive | TBD | Purchase about one week after the workstation |

Recorded one-time subtotal for explicitly ordered items: **$2,277.91**.

The Windows USB may be returned unopened, reducing the retained cost by $149.99.

## Workstation decision

The selected machine is the Amazon 64 GB / 2 TB configuration of the MINISFORUM MS-A2:

- AMD Ryzen 9 9955HX, 16 cores and 32 threads, up to 5.4 GHz
- x86-64 architecture
- 64 GB DDR5-5600 in replaceable SODIMM slots; platform supports up to 96 GB
- Factory-installed 2 TB SSD
- Windows edition must be verified on arrival
- AMD Radeon 610M integrated graphics
- Two 2.5 GbE RJ45 ports
- Two 10 Gb SFP+ ports
- Three supported storage positions across M.2/U.2 formats
- Dual-fan, four-heat-pipe cooling

The system is intentionally selected for CPU performance, replaceable memory, networking and storage expansion. Local AI inference and high-end graphics are not requirements.

Intel vPro is no longer a purchasing constraint. The external Comet KVM and Fingerbot provide the required out-of-band console and power recovery without limiting the workstation to scarce vPro configurations.

## Storage decision

Use the factory 2 TB SSD initially. Do not purchase or install the previously considered 4 TB secondary SSD yet.

Suggested layout:

- Windows 11 Pro, Office and applications
- Ubuntu Hyper-V virtual disk, Herdr and Linux repositories
- Repositories and working files
- Excel workbooks requiring native COM automation

Do not configure RAID. Additional SSD capacity can be added professionally later if actual usage justifies it.

## Windows arrival decision tree

Keep the Windows 11 Pro retail USB sealed when it arrives.

1. Boot the MS-A2 using the existing monitor and Logitech receiver.
2. If Windows is installed, open **Settings > System > Activation**.
3. If it reports **Windows 11 Pro** and an active digital license, return the unopened retail USB.
4. If it reports Windows 11 Home, use the retail Pro key to upgrade.
5. If no operating system is installed, boot from the retail USB and install Windows 11 Pro.

The purchased USB is the International English FPP package. Functionally it is the same Windows 11 Pro; choose United States region, US keyboard and English during setup. The Amazon offer was recorded as shipped by Amazon and sold by Prizm Security, so activation should be verified immediately if the package is opened.

## Excel and Herdr execution model

Windows 11 Pro runs on bare metal because native desktop Excel and its COM automation interfaces are required.

Ubuntu 24.04 LTS runs as a Generation 2 Hyper-V VM. Herdr, Git repositories and x86-64 CLI tooling run inside the VM. The VM uses normal Linux systemd and starts with the Hyper-V service independently of interactive Windows logon. Routine remote work enters through SSH or Mosh and reconnects to persistent Herdr sessions.

Initial VM allocation:

- 16 virtual processors
- Dynamic memory: 8 GB minimum, 16 GB startup and 32 GB maximum
- 500 GB dynamically expanding VHDX
- Hyper-V Default Switch initially; Tailscale supplies stable remote identity
- Automatic start action: Start, with a 30-second delay
- Automatic stop action: Save

These are ceilings, not disk preallocation. Start here and measure before assigning more resources. Windows retains enough memory and CPU capacity for desktop Excel, COM automation, backup, KVM and remote-management duties.

Excel automation must run in an interactive Windows user session:

- Keep the designated Windows automation user signed in.
- Use RDP over Tailscale when interactive Excel work is needed.
- Do not expose RDP or SSH directly to the public internet.
- Do not run Excel COM automation as a Windows service or unattended Session 0 process.
- Exchange workbooks through the restricted `HerdrExchange` SMB share mounted at `/srv/herdr-exchange` in Ubuntu.
- Invoke Excel through a reviewed Windows-side job runner in the interactive user session; Hyper-V has no WSL-style `powershell.exe` interop.

### OneDrive review exchange

Use GitHub as the source of truth for repositories and OneDrive as the human-facing exchange for one-off documents and workbook reviews. This provides a lightweight path for reviewing an STModel workbook without creating a Git branch or performing a full repository handoff.

Configure the native Windows OneDrive client with a dedicated `Herdr Review Exchange` folder containing `Inbox`, `Outbox`, and `Archive`. Mark the entire folder **Always keep on this device**. Do not install or mount OneDrive inside Ubuntu.

OneDrive is a transfer and version-history layer, not an automation workspace:

1. Upload a uniquely named workbook to `Inbox` from the laptop.
2. The reviewed staging helper must reject the `Offline`, `RecallOnOpen`, and `RecallOnDataAccess` attributes, then require unchanged size, last-write time, and SHA-256 across two exclusive reads separated by a settle interval. A green OneDrive icon or Always keep on this device request alone is not acceptance evidence.
3. Preserve the Inbox original, record its SHA-256, copy it into a job-specific directory below `C:\HerdrExchange\in`, and immediately re-hash that copy. Refuse the job unless both hashes match.
4. Ubuntu agents may inspect the bridge copy. Immediately before Excel/COM execution, the Windows runner must copy the accepted workbook into protected, host-owned `C:\HerdrReviewJobs\<job-id>`, which is not shared with `HerdrBridge`, and re-hash it against the accepted staged hash. `New-HerdrExchangeShare.ps1` establishes the DACL, the boundary test proves bridge writes fail, and Excel opens only that immutable last-mile copy.
5. Copy the completed workbook plus a small provenance manifest to `Outbox`; include the source, bridge-stage, last-mile and result paths/hashes, timestamp, and originating repository/branch/commit when applicable.
6. After acceptance, move the transfer set to `Archive` according to the retention policy.

Do not place Git working trees, Hyper-V disks, credentials, private keys, automation logs, or active databases in OneDrive. Never add the OneDrive exchange, `C:\HerdrExchange`, `C:\HerdrReviewJobs`, or any child directory as an Excel Trusted Location. Do not enable macros or external links in an untrusted workbook merely because it arrived through the exchange.

## Remote access and recovery

Normal access:

- Tailscale plus SSH or Mosh directly to the Ubuntu VM
- Tailscale plus RDP for the Windows desktop and Excel

Break-glass access:

- Comet PoE connected to the MS-A2 by HDMI and USB
- Tailscale access to the Comet browser console
- Fingerbot adhered to the MS-A2 power button
- BIOS/UEFI, Windows installer and recovery environment visible through Comet

The Comet must remain powered when the MS-A2 is off. Use PoE from a UPS-backed PoE switch/injector or an independent USB power adapter connected to the UPS. Do not power the Comet only from the MS-A2.

The Comet's 32 GB eMMC supports virtual media. Store the Veeam recovery ISO there and boot-test it from UEFI. This makes a separate physical Veeam recovery USB optional, though a USB remains a useful independent fallback.

## Monitor, keyboard and mouse

No permanent monitor is required.

Initial setup uses an existing monitor and the Logitech MK270 USB receiver. After Windows and Comet are configured, move the MS-A2 HDMI connection to the Comet. The Comet supplies display presence and remote keyboard/mouse emulation, so no HDMI dummy plug is required.

Keep the MK270 onsite for local emergencies. Remove its batteries if it will be stored unused for a long period.

## Power design

Connect the following to battery-backed outlets on the CyberPower UPS:

- MS-A2
- Comet KVM
- Router
- Ethernet switch
- Modem or fiber ONT
- External backup drive when installed

Connect the UPS USB monitoring cable to Windows and configure an orderly shutdown during an extended outage. Do not attach a laser printer, heater or downstream surge strip to the UPS.

## Backup design

The 20 TB external backup drive is intentionally deferred for approximately one week. This is acceptable while the machine is being commissioned, provided no irreplaceable file exists only on the MS-A2.

During the interim:

- Push repositories to their Git remotes.
- Keep important workbooks on the laptop, OneDrive or another independent location.
- Install Backblaze once user data is placed on the workstation.

When the backup drive arrives:

1. Install Veeam Agent for Microsoft Windows.
2. Configure an entire-computer image to the external drive.
3. Generate the Veeam recovery environment as an ISO.
4. Upload that ISO to the Comet's eMMC.
5. Save additional ISO copies on the backup drive and laptop/cloud storage.
6. Boot-test the ISO through Comet virtual media.
7. Perform a sample file restore.

Backblaze complements this system by protecting supported user data offsite. It is not a Windows system image and does not replace Veeam.

## Network decisions

- Use wired Ethernet for both the MS-A2 and Comet.
- Prefer the MS-A2 Intel I226-V 2.5 GbE interface for the primary LAN connection.
- Run Tailscale independently on Windows (`herdr-win`) and Ubuntu (`herdr-ubuntu`).
- Do not publish Hyper-V, SMB, SSH, Mosh, RDP or KVM ports through the home router.
- Restrict the Windows SMB firewall rule to the Tailscale CGNAT range and authenticate with the non-admin `HerdrBridge` account.
- Cat6 is sufficient for the present home network.
- Assign DHCP reservations to the MS-A2 and Comet.
- Do not expose KVM, RDP, SSH or management ports directly to the internet.
- Test Tailscale access from a cellular connection before traveling.

## Commissioning checklist

- [ ] Inspect the MS-A2 and packaging before modifying anything.
- [ ] Keep the Windows USB sealed until the installed edition and activation are known.
- [ ] Complete Windows 11 Pro setup and all updates.
- [ ] Install Microsoft 365 desktop Excel and verify COM automation.
- [ ] Enable Hyper-V, reboot and create the `herdr-ubuntu` VM.
- [ ] Install Ubuntu Server 24.04 LTS and confirm the VM starts before Windows login.
- [ ] Install native Ubuntu PowerShell 7 and migrate AMD64 tooling.
- [ ] Install and test Herdr persistence.
- [ ] Configure separate Windows and Ubuntu Tailscale nodes, SSH, Mosh and RDP.
- [ ] Create and write-test the restricted SMB Excel exchange.
- [ ] Sign in to OneDrive on Windows, create `Herdr Review Exchange\Inbox`, `Outbox`, and `Archive`, and mark the tree Always keep on this device.
- [ ] After the reviewed staging helper exists and passes its hydration, stability, hash and last-mile-isolation tests, complete a round-trip workbook review from laptop → OneDrive Inbox → staged SMB job → host-owned Excel job → OneDrive Outbox.
- [ ] Port the Herdr coordination payload to Linux and pass its native-`pwsh` regression suite before enabling it.
- [ ] Configure Comet, Fingerbot and independent KVM power.
- [ ] Upload and boot-test recovery virtual media.
- [ ] Configure UPS monitoring and shutdown.
- [ ] Test remote access from outside the home network.
- [ ] Cold-boot Windows without logging in and confirm `herdr-ubuntu` becomes reachable.
- [ ] Confirm Excel jobs remain gated until the interactive Windows automation user signs in.
- [ ] Add the 20 TB backup drive and configure Veeam within approximately one week.
- [ ] Install Backblaze and perform both image and file-restore tests.

## Remaining purchases or confirmations

- Obtain two Ethernet cables if suitable cables are not already available.
- Confirm an existing Microsoft 365 plan includes desktop Excel.
- Purchase the approximately 20 TB external backup drive after the workstation is commissioned.
