import json
import os
import sys
recovery_filter = os.environ.get("RECOVERY_FILTER", "none")
for line in sys.stdin:
    try:
        d = json.loads(line)
    except json.JSONDecodeError:
        continue
    if d.get("recovery") != recovery_filter:
        continue
    sk = d["sessionKey"]
    age = d["ageSeconds"]
    rec = d["recovery"]
    print("%s age=%ds recovery=%s" % (sk, age, rec))
