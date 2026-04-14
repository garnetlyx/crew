import re

log_file = "/Users/gl/.gemini/antigravity/brain/b621cfda-c1e4-4e23-bb39-42f4c81c7b1b/.system_generated/logs/overview.txt"
with open(log_file, "r") as f:
    text = f.read()

# find the view_file block for AUDIT_MODE_DESIGN.md
start_idx = text.find("Please note that any changes targeting the original code should remove the line number, colon, and leading space.")
if start_idx != -1:
    start_idx = text.find("1: # crew - Audit Mode Design", start_idx)
    end_idx = text.find("The above content shows the entire, complete file contents", start_idx)
    
    if start_idx != -1 and end_idx != -1:
        chunk = text[start_idx:end_idx]
        lines = chunk.split("\n")
        
        restored = []
        for line in lines:
            line = line.rstrip()
            if not line:
                continue
            # match exactly digit(s): space
            m = re.match(r'^(\d+):\s(.*)$', line)
            if m:
                restored.append(m.group(2))
            else:
                m_empty = re.match(r'^(\d+):$', line)
                if m_empty:
                    restored.append("")
                else:
                    restored.append(line)
        
        with open("/Users/gl/dev/garnetlyx/crew/docs/AUDIT_MODE_DESIGN.md", "w") as out:
            out.write("\n".join(restored) + "\n")
        print("Restored successfully")
    else:
        print("Could not find boundaries")
else:
    print("Could not find start")
