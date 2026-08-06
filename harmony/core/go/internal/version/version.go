package version

import (
	"crypto/sha256"
	"encoding/hex"

	"github.com/metacubex/mihomo/constant"
)

const abiVersion = "cmfa-harmony-v1"

var upstreamCommit = "e26714a181ac0e2fa803453c0a8e9a9ce94e31cb"
var buildID = ""

type Info struct {
	Version        string `json:"version"`
	UpstreamCommit string `json:"upstreamCommit"`
	ABIVersion     string `json:"abiVersion"`
	BuildID        string `json:"buildId"`
}

func Mihomo() string {
	return constant.Version
}

func Build() Info {
	info := Info{
		Version:        Mihomo(),
		UpstreamCommit: upstreamCommit,
		ABIVersion:     abiVersion,
	}
	if buildID != "" {
		info.BuildID = buildID
		return info
	}
	digest := sha256.Sum256([]byte(info.Version + "|" + info.UpstreamCommit + "|" + info.ABIVersion))
	info.BuildID = hex.EncodeToString(digest[:8])
	return info
}
