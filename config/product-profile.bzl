"""Validated native profile selection; unknown names must never select development."""

def _profile_impl(ctx):
    if ctx.build_setting_value not in ["development", "publication"]:
        fail("Unknown product profile: " + ctx.build_setting_value)
    return []

product_profile = rule(
    implementation = _profile_impl,
    build_setting = config.string(flag = True),
)
