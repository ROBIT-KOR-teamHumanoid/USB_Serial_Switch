# Node output filter for robot_manager.sh (stdin -> stdout).
#
# Keeps only error/warning lines, plus process start/exit lines, the dhi
# "activated" line that robot_manager.sh waits for in its torque check, and
# the realsense refiner "[depth stream]" status lines (incl. OK / recovered).
#
# fold=1 : a line repeated back to back (ignoring numbers such as timestamps)
#          is written once, followed by a "repeated N times" note.
#          dhi runs with fold=0: its errors are already throttled to 1/sec and
#          the motor-power check needs every fresh "Failed to read" line.

function flush_repeat()
{
    if (repeat > 0)
    {
        print "    ... previous line repeated " repeat " more times"
        fflush()
        repeat = 0
    }
}

BEGIN {
    keep = "ERROR|FATAL|WARN|Traceback|Exception|Error:|" \
           "process started|process has died|process has finished|" \
           "Dynamixel hardware interface activated|" \
           "\\[depth stream\\]"

    # shown in red (cat / tail -f / less -R): errors, crashes, exceptions
    red = "ERROR|FATAL|process has died|Traceback|Exception|Error:"
    RED = "\033[31m"
    RESET = "\033[0m"
}

function out(line)
{
    if (line ~ red)
        print RED line RESET
    else
        print line
    fflush()
}

$0 ~ keep {
    if (fold)
    {
        key = $0
        gsub(/[0-9]+/, "#", key)

        if (key == last)
        {
            repeat++
            if (repeat % 1000 == 0)
            {
                print "    ... previous line repeated " repeat " times so far"
                fflush()
            }
            next
        }

        flush_repeat()
        last = key
    }

    out($0)
}

END {
    flush_repeat()
}
