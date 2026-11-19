<#
    A name for a temporary file, unique to this RUN.

    WHAT HAPPENED, 2026-09-17, stopping `azd up` after the facade had already
    published:

      New-Object: Exception calling ".ctor" with "2" argument(s): "The process
      cannot access the file 'C:\Users\...\Temp\vmf-dash-28800.zip' because it
      is being used by another process."

    WHAT HELD THE FILE IS NOT KNOWN, and this comment does not pretend
    otherwise. By the time it was looked into, process 28800 was gone and the
    file was gone. Two theories were checked on the machine that failed and
    both were wrong: it was not a managed corporate machine (it was the
    personal one), and Windows Defender real-time protection is switched OFF
    there, so it was not a scanner either.

    SO THE FIX DOES NOT DEPEND ON KNOWING. Whatever held it, two things here
    were wrong on their own terms:

      1. THE NAME CAME FROM `$PID`, which is not unique. Windows recycles
         process ids; azd starts a fresh process for each hook, so the id says
         nothing about which deployment is writing; and two scripts in one
         process share it exactly. A leftover file from any earlier run could
         therefore be the file this run opens.

      2. THE ZIP WAS REMOVED ONLY ON THE SUCCESS PATH. The `finally` cleaned
         the staging folder and the config and not the zip, so every failed
         publish left one behind - and 2026-09-17 had a great many failed
         publishes.

    A unique name means a leftover can never be reopened. Cleanup in `finally`
    means leftovers stop being made. Neither needs a theory about the holder.

    And where a write meets a held file anyway, the caller waits a moment, tries
    again, and then SAYS WHICH FILE - because the .NET message names a process
    and not which process, nor what the file was for. A deployment that stops
    must say where it stopped.
#>

function New-VmfRunTag {
    <#
    .SYNOPSIS
        A short tag unique to this run, for naming a temporary file.
    .DESCRIPTION
        Eight hex characters from a new GUID. Long enough that two runs a
        second apart cannot collide, short enough to read in an error message.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    [guid]::NewGuid().ToString('N').Substring(0, 8)
}
