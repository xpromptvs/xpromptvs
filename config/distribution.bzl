"""Source builds stay isolated unless the publisher explicitly selects official."""
def _impl(ctx):
    if ctx.build_setting_value not in ["source", "official"]:
        fail("Unknown app distribution: " + ctx.build_setting_value)
    return []
app_distribution = rule(implementation = _impl, build_setting = config.string(flag = True))
