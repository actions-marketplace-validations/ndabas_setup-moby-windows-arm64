; Installer for the Windows ARM64 build of the moby Docker engine. The binaries
; are installed, upgraded and uninstalled by Install-Moby.ps1, which this
; installer bundles.
;
; Build with:
;   makensis /DBINDIR=C:\path\to\docker-bin /DVERSION=29.9.0 /DOUTFILE=C:\path\to\docker-windows-arm64-setup.exe installer\moby.nsi
;
; BINDIR is the directory containing docker.exe and dockerd.exe.

Unicode true

!ifndef BINDIR
  !error "Define BINDIR as the directory containing docker.exe and dockerd.exe, e.g. makensis /DBINDIR=C:\docker-bin"
!endif
!ifndef VERSION
  !define VERSION "local"
!endif
!ifndef OUTFILE
  !define OUTFILE "docker-windows-arm64-setup.exe"
!endif

!define UNINSTALL_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\moby"
; The installer is an x86 process, so use Sysnative to run the native PowerShell;
; DISM cmdlets such as Enable-WindowsOptionalFeature don't work under WOW64.
!define POWERSHELL '"$WINDIR\Sysnative\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass'

!include LogicLib.nsh
!include x64.nsh

ManifestDPIAware true
RequestExecutionLevel admin
SetCompressor /SOLID lzma

Name "Moby (Docker engine) ${VERSION} for Windows ARM64"
OutFile "${OUTFILE}"
InstallDir "$PROGRAMFILES64\moby"
InstallDirRegKey HKLM "${UNINSTALL_KEY}" "InstallLocation"
ShowInstDetails show
ShowUninstDetails show

Page directory
Page instfiles

UninstPage uninstConfirm
UninstPage instfiles

Function .onInit
  ${IfNot} ${IsNativeARM64}
    MessageBox MB_ICONSTOP "This installer is for Windows ARM64." /SD IDOK
    Abort
  ${EndIf}
FunctionEnd

Section "Install"
  InitPluginsDir
  SetOutPath "$PLUGINSDIR\bin"
  File "${BINDIR}\*.exe"
  SetOutPath "$INSTDIR"
  File "..\Install-Moby.ps1"

  ; Install-Moby.ps1 stops a running docker service before replacing the binaries,
  ; so they are staged in $PLUGINSDIR rather than written to $INSTDIR directly.
  nsExec::ExecToLog '${POWERSHELL} -File "$INSTDIR\Install-Moby.ps1" -SourcePath "$PLUGINSDIR\bin" -InstallPath "$INSTDIR"'
  Pop $0
  ${If} $0 != 0
    DetailPrint "Install-Moby.ps1 failed with exit code $0."
    SetOutPath "$TEMP"
    Abort "Installation failed."
  ${EndIf}

  WriteUninstaller "$INSTDIR\uninstall.exe"
  WriteRegStr HKLM "${UNINSTALL_KEY}" "DisplayName" "Moby (Docker engine) for Windows ARM64"
  WriteRegStr HKLM "${UNINSTALL_KEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKLM "${UNINSTALL_KEY}" "DisplayIcon" "$INSTDIR\dockerd.exe"
  WriteRegStr HKLM "${UNINSTALL_KEY}" "Publisher" "setup-moby-windows-arm64"
  WriteRegStr HKLM "${UNINSTALL_KEY}" "URLInfoAbout" "https://github.com/ndabas/setup-moby-windows-arm64"
  WriteRegStr HKLM "${UNINSTALL_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKLM "${UNINSTALL_KEY}" "UninstallString" '"$INSTDIR\uninstall.exe"'
  WriteRegStr HKLM "${UNINSTALL_KEY}" "QuietUninstallString" '"$INSTDIR\uninstall.exe" /S'
  WriteRegDWORD HKLM "${UNINSTALL_KEY}" "NoModify" 1
  WriteRegDWORD HKLM "${UNINSTALL_KEY}" "NoRepair" 1

  ; Install-Moby.ps1 doesn't start the service if enabling the Containers feature needs a restart.
  nsExec::Exec `${POWERSHELL} -Command "exit [int]((Get-WindowsOptionalFeature -Online -FeatureName Containers).State -ne 'Enabled')"`
  Pop $0
  ${If} $0 != 0
    SetRebootFlag true
  ${EndIf}

  SetOutPath "$TEMP"
SectionEnd

Function .onInstSuccess
  ${If} ${RebootFlag}
  ${AndIf} ${Cmd} `MessageBox MB_YESNO|MB_ICONQUESTION "Windows must be restarted to finish enabling the Containers feature. The docker service will start after the restart.$\n$\nRestart now?" /SD IDNO IDYES`
    Reboot
  ${EndIf}
FunctionEnd

Section "Uninstall"
  SetOutPath "$TEMP"
  nsExec::ExecToLog '${POWERSHELL} -File "$INSTDIR\Install-Moby.ps1" -Uninstall -InstallPath "$INSTDIR"'
  Pop $0
  ${If} $0 != 0
    DetailPrint "Install-Moby.ps1 -Uninstall failed with exit code $0."
    Abort "Uninstallation failed."
  ${EndIf}

  Delete "$INSTDIR\Install-Moby.ps1"
  Delete "$INSTDIR\uninstall.exe"
  RMDir "$INSTDIR"
  DeleteRegKey HKLM "${UNINSTALL_KEY}"
SectionEnd
