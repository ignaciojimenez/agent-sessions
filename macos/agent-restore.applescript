-- Agent Restore: agent-restore for Spotlight. Shows the plan, asks, reopens.
--
-- Template: install.sh fills in the two values below and compiles it into
-- ~/Applications/Agent Restore.app. An app gets a bare PATH, so install.sh
-- bakes in where it found jq and git rather than guessing.

property tool : "@@TOOL@@"
property searchPath : "@@PATH@@"

on run
	set restore to "PATH=" & quoted form of searchPath & " " & quoted form of tool & " restore"
	try
		set plan to do shell script restore & " -n"
	on error errorText
		display alert "Agent Restore" message errorText as critical
		return
	end try
	if plan contains "Nothing to reopen." then
		display dialog plan with title "Agent Restore" buttons {"OK"} default button "OK"
		return
	end if
	-- Cancel ends the script here (error -128), which is the intent.
	display dialog plan with title "Agent Restore" buttons {"Cancel", "Reopen"} ¬
		default button "Reopen" cancel button "Cancel"
	try
		do shell script restore & " -y"
	on error errorText
		display alert "Agent Restore" message errorText as critical
	end try
end run
