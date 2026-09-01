package config

import (
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	mihomocfg "github.com/metacubex/mihomo/config"
	mihomoconstant "github.com/metacubex/mihomo/constant"
	mihomoexecutor "github.com/metacubex/mihomo/hub/executor"
)

var (
	ErrContentURIUnsupported = errors.New("content URI is not supported")
	ErrPathOutsideSandbox    = errors.New("path is outside the sandbox root")
	defaultHomeManager       = NewHomeManager(mihomoconstant.SetHomeDir)

	linePattern       = regexp.MustCompile(`(?i)\bline\s+(\d+)\b`)
	ruleIndexPattern  = regexp.MustCompile(`(?i)\brules?\[(\d+)\]`)
	proxyIndexPattern = regexp.MustCompile(`(?i)\bproxy(?: group)?\s+(\d+)\b`)

	allowedValidationCodes = map[string]struct{}{
		"GEODATA_MISSING":    {},
		"YAML_SYNTAX":        {},
		"PROXY_INVALID":      {},
		"RULE_INVALID":       {},
		"VALIDATION_UNKNOWN": {},
	}
	allowedValidationFields = map[string]struct{}{
		"proxy":   {},
		"rules":   {},
		"geoip":   {},
		"geosite": {},
		"asn":     {},
	}
)

func ValidateFile(sandboxRoot, candidate string) error {
	return ValidateFileWithDeps(sandboxRoot, candidate, ValidateDeps{})
}

type ValidateDeps struct {
	PrepareHome PrepareHomeFunc
	ParseBytes  ParseBytesFunc
}

func ValidateFileWithDeps(sandboxRoot, candidate string, deps ValidateDeps) error {
	_, _, err := parseWithinSandbox(sandboxRoot, candidate, resolvePrepareHome(deps.PrepareHome), resolveParseBytes(deps.ParseBytes))
	return err
}

type ParseBytesFunc func([]byte) (*mihomocfg.Config, error)

type ValidationError struct {
	Code  string
	Field string
	Index *int
	Line  *int
}

func (e *ValidationError) Error() string {
	if e == nil {
		return ""
	}

	code := e.Code
	if code == "" {
		code = "VALIDATION_UNKNOWN"
	}

	parts := []string{code}
	if e.Field != "" {
		parts = append(parts, "field="+e.Field)
	}
	if e.Index != nil {
		parts = append(parts, "index="+strconv.Itoa(*e.Index))
	}
	if e.Line != nil {
		parts = append(parts, "line="+strconv.Itoa(*e.Line))
	}

	message := strings.Join(parts, " ")
	if len(message) > 160 {
		return message[:160]
	}
	return message
}

func parseWithinSandbox(sandboxRoot, candidate string, prepareHome PrepareHomeFunc, parse ParseBytesFunc) (string, *mihomocfg.Config, error) {
	resolvedRoot, resolvedPath, body, err := readWithinSandbox(sandboxRoot, candidate)
	if err != nil {
		return "", nil, err
	}
	if prepareHome != nil {
		if err := prepareHome(resolvedRoot); err != nil {
			return "", nil, err
		}
	}

	cfg, err := parse(body)
	if err != nil {
		return "", nil, sanitizeValidationError(err)
	}

	return resolvedPath, cfg, nil
}

func readWithinSandbox(sandboxRoot, candidate string) (string, string, []byte, error) {
	if strings.HasPrefix(candidate, "content://") {
		return "", "", nil, ErrContentURIUnsupported
	}

	root, err := canonicalRoot(sandboxRoot)
	if err != nil {
		return "", "", nil, redactManagedConfigPathError(err)
	}

	if filepath.IsAbs(candidate) {
		return "", "", nil, ErrPathOutsideSandbox
	}

	target := filepath.Clean(candidate)
	if target == "." || target == "" {
		return "", "", nil, ErrPathOutsideSandbox
	}
	if target == ".." || strings.HasPrefix(target, ".."+string(filepath.Separator)) {
		return "", "", nil, ErrPathOutsideSandbox
	}

	sandbox, err := os.OpenRoot(root)
	if err != nil {
		return "", "", nil, redactManagedConfigPathError(err)
	}
	defer sandbox.Close()

	body, err := sandbox.ReadFile(target)
	if err != nil {
		targetPath := filepath.Join(root, target)
		if info, statErr := os.Lstat(targetPath); statErr == nil {
			if info.Mode()&os.ModeSymlink != 0 {
				if resolvedTarget, evalErr := filepath.EvalSymlinks(targetPath); evalErr == nil {
					if rel, relErr := filepath.Rel(root, resolvedTarget); relErr != nil || !filepath.IsLocal(rel) {
						return "", "", nil, ErrPathOutsideSandbox
					}
				}
			}
		}
		return "", "", nil, redactManagedConfigPathError(err)
	}

	return root, filepath.Join(root, target), body, nil
}

func resolveParseBytes(parse ParseBytesFunc) ParseBytesFunc {
	if parse != nil {
		return parse
	}
	return mihomoexecutor.ParseWithBytes
}

func resolvePrepareHome(prepare PrepareHomeFunc) PrepareHomeFunc {
	if prepare != nil {
		return prepare
	}
	return defaultHomeManager.Prepare
}

func sanitizeValidationError(err error) error {
	if err == nil {
		return nil
	}

	var validationErr *ValidationError
	if errors.As(err, &validationErr) && validationErr != nil {
		return rebuildValidationError(validationErr.Code, validationErr.Field, validationErr.Index, validationErr.Line)
	}

	text := err.Error()
	lower := strings.ToLower(text)

	switch {
	case isGeodataMissing(lower):
		return rebuildValidationError("GEODATA_MISSING", geodataField(lower), nil, captureInt(linePattern, text))
	case isRuleValidationError(lower):
		return rebuildValidationError("RULE_INVALID", "rules", captureInt(ruleIndexPattern, text), captureInt(linePattern, text))
	case isProxyValidationError(lower):
		return rebuildValidationError("PROXY_INVALID", "proxy", captureInt(proxyIndexPattern, text), captureInt(linePattern, text))
	case isYAMLSyntaxError(lower):
		return rebuildValidationError("YAML_SYNTAX", "", nil, captureInt(linePattern, text))
	default:
		return rebuildValidationError("VALIDATION_UNKNOWN", "", nil, captureInt(linePattern, text))
	}
}

func isGeodataMissing(lower string) bool {
	if !(strings.Contains(lower, "geoip") || strings.Contains(lower, "geosite") || strings.Contains(lower, "mmdb") || strings.Contains(lower, "asn")) {
		return false
	}
	return strings.Contains(lower, "can't find") ||
		strings.Contains(lower, "cannot find") ||
		strings.Contains(lower, "not find") ||
		strings.Contains(lower, "no such file") ||
		strings.Contains(lower, "missing")
}

func geodataField(lower string) string {
	switch {
	case strings.Contains(lower, "geosite"):
		return "geosite"
	case strings.Contains(lower, "asn"):
		return "asn"
	default:
		return "geoip"
	}
}

func isRuleValidationError(lower string) bool {
	return strings.Contains(lower, "rules[") ||
		strings.Contains(lower, "rule[") ||
		strings.Contains(lower, "sub-rule") ||
		strings.Contains(lower, "rule set")
}

func isProxyValidationError(lower string) bool {
	return strings.HasPrefix(lower, "proxy ") ||
		strings.HasPrefix(lower, "proxy group") ||
		strings.Contains(lower, "proxy[") ||
		strings.Contains(lower, "proxy group[")
}

func isYAMLSyntaxError(lower string) bool {
	return strings.Contains(lower, "yaml:") ||
		strings.Contains(lower, "cannot unmarshal") ||
		strings.Contains(lower, "mapping values are not allowed")
}

func captureInt(pattern *regexp.Regexp, text string) *int {
	matches := pattern.FindStringSubmatch(text)
	if len(matches) != 2 {
		return nil
	}
	value, err := strconv.Atoi(matches[1])
	if err != nil {
		return nil
	}
	return &value
}

func rebuildValidationError(code, field string, index, line *int) *ValidationError {
	sanitized := &ValidationError{
		Code:  sanitizeValidationCode(code),
		Field: sanitizeValidationField(field),
		Index: sanitizeValidationNumber(index),
		Line:  sanitizeValidationNumber(line),
	}
	if sanitized.Code == "VALIDATION_UNKNOWN" {
		sanitized.Field = ""
	}
	return sanitized
}

func sanitizeValidationCode(code string) string {
	if _, ok := allowedValidationCodes[code]; ok {
		return code
	}
	return "VALIDATION_UNKNOWN"
}

func sanitizeValidationField(field string) string {
	if _, ok := allowedValidationFields[field]; ok {
		return field
	}
	return ""
}

func sanitizeValidationNumber(value *int) *int {
	if value == nil || *value < 0 || *value > 999999 {
		return nil
	}
	safe := *value
	return &safe
}
