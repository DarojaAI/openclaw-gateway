import json, sys
print(json.load(sys.stdin)[sys.argv[1]])
