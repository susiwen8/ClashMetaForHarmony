# Subscription Validation Compatibility

## Safe Findings

- Missing product User-Agent returns a Base64 URI list response class.
- `ClashMetaForAndroid/HarmonyOS` returns a full Clash YAML response class.
- Initial parser replay is categorized as `GEODATA_MISSING` on the first rule entry.
- Prepared-home replay with verified `geoip.metadb` wiring is accepted.

## Selected Fixes

- Downloader requests always send the exact product User-Agent and stage the server YAML payload verbatim.
- Validation replays use prepared-home injection so the canonical GeoIP filename can be required without checking in the binary asset.

## Pinned Geodata Identity

- Canonical name: `geoip.metadb`
- Size: `8593535`
- SHA-256: `71def3ab45393093baf9d39b69787b3e0d0685607c13dd135bfdbb603bd475dd`

- Review note (2026-08-22): official release API size/digest were re-verified as `8593535` and `sha256:71def3ab45393093baf9d39b69787b3e0d0685607c13dd135bfdbb603bd475dd`, and a real `mihomo v1.19.29` `ParseWithBytes` replay accepted the prepared-home fixture.

## Redaction Controls

- No subscription URL, token, endpoint, node name, group name, credential, absolute path, parser text, or response bytes are stored in this report.
- Evidence is limited to response class, validation category, first-rule placement, and pinned asset identity.
- Credentials are redacted in fixtures, tests, and documentation.

## Plan A Task 6 Safe Status

- `step1_go_zero_failure`: true
- `step1_platform_tests_pass`: true
- `step1_entry_only_allowlist_failures`: true
- `step1_structure_contracts_pass`: true
- `step2_build_profile_started_safe_empty`: true
- `step2_build_profile_restored_exact_bytes`: true
- `step2_signing_temp_empty`: true
- `step2_cleanup_safe_empty`: true
- `step2_compat_contract_pass`: true
- `step2_prebuild_task_tree_pass`: true
- `step2_phase1_native_manifest_pass`: true
- `step2_inspect_hap_production_pass`: true
- `step2_task_tree_contract_pass`: true
- `step2_signing_isolation_pass`: true
- `step2_geodata_prepare_pass`: true
- `step2_package_hap_pass`: true
- `step3_device_install_refresh_executed`: true
- `step4_device_evidence_collected`: true
- `step4_geodata_installed_lock_match`: true
- `step4_refresh_valid_current_error_null`: true
- `step4_yaml_mapping_not_base64`: true
- `step4_huks_ref_unchanged`: true
- `step4_huks_envelope_unchanged`: true
- `step5_runtime_gate_executed`: true
- `step5_enable_active_match`: true
- `step5_config_loaded_causal`: true
- `step5_config_loaded_direct`: false
