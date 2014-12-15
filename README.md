SQLServerDisasterRecovery
=========================

T-SQL and PowerShell scripts which relate to disaster recovery or high-availability in any way.

----------

**AvailabilityGroupFailoverTest.ps1**

This script was designed to make failing over Availability Groups easy, when in a testing scenario. There were three major goals.

- One line of code to execute.
- Configurations can be saved in advance and re-used.
- AGs using asynchronous commit can achieve zero data loss fail-overs.
 
To achieve these goals I decided to use JSON files as my save-able configurations. You may enter a file path to a JSON file or pass in a string that contains JSON. This JSON object defines your target configuration and the script will work towards migrating, safely, from the current configuration to the target.

*See test files (FailoverTest_1.txt and FailoverTest_2.txt) for the required JSON elements and properties.*

----------
  
