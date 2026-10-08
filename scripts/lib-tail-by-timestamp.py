import datetime as dt
import sys

path = sys.argv[1]
cutoff = dt.datetime.utcnow() - dt.timedelta(minutes=5)
out = []
with open(path, errors="replace") as fh:
    for line in fh:
        # Lines look like: "Jun 28 18:48:41 host openclaw[336954]: ..."
        try:
            ts = dt.datetime.strptime(line[:15], "%b %d %H:%M:%S")
            ts = ts.replace(year=dt.datetime.utcnow().year)
            if ts >= cutoff:
                out.append(line)
        except ValueError:
            continue
sys.stdout.write("".join(out))
