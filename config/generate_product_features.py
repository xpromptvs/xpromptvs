"""Generate native constants from the same checked-in profile Vite resolves."""
import json, sys
source, profile, out = sys.argv[1:]
profiles = json.load(open(source))
if profile not in profiles:
    raise SystemExit('Unknown product profile: ' + profile)
values = profiles[profile]
if set(values) != {'graphicalAgents', 'glasses'} or any(type(v) is not bool for v in values.values()):
    raise SystemExit('Invalid product features')
with open(out, 'w') as dest:
    dest.write('// Generated from config/product-features.json.\npublic enum ProductFeatures {\n')
    for key, value in values.items():
        dest.write('    public static let %s = %s\n' % (key, str(value).lower()))
    dest.write('}\n')
