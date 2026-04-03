package com.odinone.desktop.vk

import app.tauri.plugin.JSObject
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class VpnRuntimeLibboxTest {
    @Test
    fun stableRealityDefaultsRemainConservative() {
        val normalized =
            VpnRuntimeLibbox.normalizeRuntimeArgs(
                JSObject().apply {
                    put("serverHost", "example.com")
                    put("transport", "xray")
                    put("engine", "sing-box")
                    put("protocol", "vless-reality")
                    put("profileJson", """{"stagedFallbacks":{"vlessReality":{"port":443}}}""")
                },
            )

        assertEquals("stable", normalized.getString("configMode", null))
        assertEquals("udp", normalized.getString("dnsMode", null))
        assertFalse(normalized.getBoolean("strictRoute", true))
        assertFalse(normalized.getBoolean("bootRestoreEnabled", true))
        assertTrue(normalized.getBoolean("allowPrivateNetworkBypass", false))
        assertEquals(0, normalized.optJSONArray("privateBypassCidrs")?.length() ?: 0)
        assertFalse(normalized.getBoolean("networkReloadOnChange", true))
        assertEquals(1500L, normalized.optLong("networkReloadDebounceMs", 0L))
        assertEquals("1.1.1.1", normalized.getString("dnsServer", null))
        assertEquals("cloudflare-dns.com", normalized.getString("dnsServerName", null))
        assertEquals("/dns-query", normalized.getString("dnsDohPath", null))
        assertEquals("prefer_ipv4", normalized.getString("dnsStrategy", null))
        assertFalse(normalized.getBoolean("dnsDisableCache", true))
        assertFalse(normalized.getBoolean("dnsIndependentCache", true))
        assertFeature(normalized, "mux:disabled")
        assertFeature(normalized, "family:direct-reality")
        assertFeature(normalized, "activation:active")
        assertFeature(normalized, "dns:udp")
        assertFeature(normalized, "resolver:1.1.1.1")
        assertFeature(normalized, "dns-strategy:prefer_ipv4")
        assertFeature(normalized, "mode:stable")
        assertFeature(normalized, "private-bypass:on")
        assertTrue((normalized.getString("profileHash", null) ?: "").isNotBlank())
    }

    @Test
    fun experimentalRealityFlagsAreNormalizedFromProfile() {
        val normalized =
            VpnRuntimeLibbox.normalizeRuntimeArgs(
                JSObject().apply {
                    put("serverHost", "example.com")
                    put("transport", "xray")
                    put("engine", "sing-box")
                    put("protocol", "vless-reality")
                    put(
                        "profileJson",
                        """
                        {
                          "androidRuntime": {
                            "reality": {
                              "mode": "experimental",
                              "dnsMode": "doh",
                              "strictRoute": true,
                              "allowPrivateNetworkBypass": false,
                              "autoRestoreOnBoot": true,
                              "networkReloadOnChange": true,
                              "networkReloadDebounceMs": 2200,
                              "dnsServer": "8.8.8.8",
                              "dnsServerName": "dns.google",
                              "dnsServerPort": 8443,
                              "dnsDohPath": "resolve",
                              "dnsStrategy": "ipv6_only",
                              "dnsDisableCache": true,
                              "dnsIndependentCache": true,
                              "excludePackages": [
                                "com.android.captiveportallogin",
                                "com.google.android.gms"
                              ],
                              "tlsFragment": true,
                              "recordFragment": true
                            }
                          }
                        }
                        """.trimIndent(),
                    )
                },
            )

        assertEquals("experimental", normalized.getString("configMode", null))
        assertEquals("doh", normalized.getString("dnsMode", null))
        assertTrue(normalized.getBoolean("strictRoute", false))
        assertTrue(normalized.getBoolean("bootRestoreEnabled", false))
        assertFalse(normalized.getBoolean("allowPrivateNetworkBypass", true))
        assertTrue(normalized.getBoolean("networkReloadOnChange", false))
        assertEquals(2200L, normalized.optLong("networkReloadDebounceMs", 0L))
        assertEquals("8.8.8.8", normalized.getString("dnsServer", null))
        assertEquals("dns.google", normalized.getString("dnsServerName", null))
        assertEquals(8443, normalized.optInt("dnsServerPort"))
        assertEquals("/resolve", normalized.getString("dnsDohPath", null))
        assertEquals("ipv6_only", normalized.getString("dnsStrategy", null))
        assertTrue(normalized.getBoolean("dnsDisableCache", false))
        assertTrue(normalized.getBoolean("dnsIndependentCache", false))
        assertEquals(2, normalized.optJSONArray("excludePackages")?.length())
        assertTrue(normalized.getBoolean("tlsFragment", false))
        assertTrue(normalized.getBoolean("recordFragment", false))
        assertFeature(normalized, "dns:doh")
        assertFeature(normalized, "resolver:8.8.8.8")
        assertFeature(normalized, "dns-strategy:ipv6_only")
        assertFeature(normalized, "dns-cache:disabled")
        assertFeature(normalized, "dns-cache:independent")
        assertFeature(normalized, "pkg-exclude:2")
        assertFeature(normalized, "family:direct-reality")
        assertFeature(normalized, "activation:active")
        assertFeature(normalized, "strict-route")
        assertFeature(normalized, "boot-restore")
        assertFeature(normalized, "net-reload:2200ms")
        assertFeature(normalized, "tls-fragment")
        assertFeature(normalized, "tls-record-fragment")
        assertFeature(normalized, "private-bypass:off")
    }

    @Test
    fun selectivePrivateBypassCidrsDisableBroadPrivateDirectRule() {
        val normalized =
            VpnRuntimeLibbox.normalizeRuntimeArgs(
                JSObject().apply {
                    put("serverHost", "example.com")
                    put("transport", "xray")
                    put("engine", "sing-box")
                    put("protocol", "vless-reality")
                    put(
                        "profileJson",
                        """
                        {
                          "androidRuntime": {
                            "reality": {
                              "mode": "stable",
                              "strictRoute": true,
                              "privateBypassCidrs": [
                                "10.0.0.0/8",
                                "192.168.0.0/16",
                                "169.254.0.0/16"
                              ]
                            }
                          }
                        }
                        """.trimIndent(),
                    )
                },
            )

        assertFalse(normalized.getBoolean("allowPrivateNetworkBypass", true))
        val selectiveCidrs = normalized.optJSONArray("privateBypassCidrs")
        assertEquals(3, selectiveCidrs?.length())
        assertEquals("10.0.0.0/8", selectiveCidrs?.optString(0))
        assertEquals("192.168.0.0/16", selectiveCidrs?.optString(1))
        assertEquals("169.254.0.0/16", selectiveCidrs?.optString(2))
        assertFeature(normalized, "strict-route")
        assertFeature(normalized, "private-bypass:selective:3")
    }

    @Test
    fun cdnAntiWhitelistProfileSelectsScaffoldFamily() {
        val normalized =
            VpnRuntimeLibbox.normalizeRuntimeArgs(
                JSObject().apply {
                    put("serverHost", "example.com")
                    put("transport", "xray")
                    put("engine", "sing-box")
                    put("protocol", "vless-reality")
                    put(
                        "profileJson",
                        """
                        {
                          "stagedFallbacks": {
                            "vlessReality": {
                              "port": 443,
                              "uuid": "9425da86-1560-4f77-ac53-076a2fa7eecd",
                              "serverName": "www.cloudflare.com",
                              "publicKey": "HR2qUZNinSLuJx2-dvQNMpjEyqZ6spD-8TNzGEwuyW8",
                              "shortId": "9a3d8b86a93616a7"
                            }
                          },
                          "androidRuntime": {
                            "cdnAntiWhitelist": {
                              "enabled": true,
                              "provider": "cloudflare",
                              "transport": "xhttp",
                              "frontSelection": "ordered",
                              "frontPool": [
                                {
                                  "host": "edge-a.example.com",
                                  "port": 443,
                                  "connectHost": "connect-a.example.net",
                                  "connectPort": 9443,
                                  "path": "odin-a",
                                  "tlsServerName": "front-a.example.com",
                                  "hostHeader": "allowed-a.example.com",
                                  "provider": "cloudflare",
                                  "tag": "primary-whitelist"
                                },
                                {
                                  "host": "edge-b.example.com",
                                  "port": 8443,
                                  "connectHost": "connect-b.example.net",
                                  "connectPort": 10443,
                                  "path": "/odin-b",
                                  "tlsServerName": "front-b.example.com",
                                  "hostHeader": "allowed-b.example.com",
                                  "provider": "cloudflare",
                                  "tag": "backup-whitelist"
                                }
                              ],
                              "origin": {
                                "host": "origin.example.com",
                                "port": 443,
                                "scheme": "https",
                                "path": "/odin-origin"
                              },
                              "bootstrap": "direct-reality"
                            }
                          }
                        }
                        """.trimIndent(),
                    )
                },
            )

        assertEquals("cdn-anti-whitelist", normalized.getString("runtimeFamily", null))
        assertEquals("scaffold_only", normalized.getString("activationState", null))
        assertEquals("scaffold", normalized.getString("configMode", null))
        assertEquals("cloudflare", normalized.getString("cdnProvider", null))
        assertEquals("xhttp", normalized.getString("cdnTransport", null))
        assertEquals("edge-a.example.com", normalized.getString("frontHost", null))
        assertEquals("connect-a.example.net", normalized.getString("frontConnectHost", null))
        assertEquals(9443, normalized.optInt("frontConnectPort", 0))
        assertEquals("/odin-a", normalized.getString("frontPath", null))
        assertEquals("cloudflare", normalized.getString("frontProvider", null))
        assertEquals("primary-whitelist", normalized.getString("frontTag", null))
        assertEquals("edge-a.example.com", normalized.getString("cdnFrontHost", null))
        assertEquals(443, normalized.optInt("cdnFrontPort", 0))
        assertEquals("connect-a.example.net", normalized.getString("cdnConnectHost", null))
        assertEquals(9443, normalized.optInt("cdnConnectPort", 0))
        assertEquals("/odin-a", normalized.getString("cdnFrontPath", null))
        assertEquals("front-a.example.com", normalized.getString("cdnTlsServerName", null))
        assertEquals("allowed-a.example.com", normalized.getString("cdnHttpHostHeader", null))
        assertEquals("primary-whitelist", normalized.getString("cdnFrontTag", null))
        assertEquals("ordered", normalized.getString("cdnFrontSelection", null))
        assertEquals(2, normalized.optInt("cdnFrontPoolSize", 0))
        assertEquals("origin.example.com", normalized.getString("cdnOriginHost", null))
        assertEquals(443, normalized.optInt("cdnOriginPort", 0))
        assertEquals("https", normalized.getString("cdnOriginScheme", null))
        assertEquals("/odin-origin", normalized.getString("cdnOriginPath", null))
        assertFalse(normalized.getBoolean("bootRestoreEnabled", true))
        assertFeature(normalized, "family:cdn-anti-whitelist")
        assertFeature(normalized, "activation:scaffold_only")
        assertFeature(normalized, "cdn-provider:cloudflare")
        assertFeature(normalized, "cdn-transport:xhttp")
        assertFeature(normalized, "cdn-front-port:443")
        assertFeature(normalized, "cdn-connect:connect-a.example.net")
        assertFeature(normalized, "cdn-connect-port:9443")
        assertFeature(normalized, "cdn-front-sni:front-a.example.com")
        assertFeature(normalized, "cdn-http-host:allowed-a.example.com")
        assertFeature(normalized, "cdn-front-tag:primary-whitelist")
        assertFeature(normalized, "cdn-front-selection:ordered")
        assertFeature(normalized, "cdn-front-pool:2")
        assertFeature(normalized, "cdn-origin-port:443")
        assertFeature(normalized, "cdn-origin-scheme:https")
        assertFeature(normalized, "cdn-origin-path:/odin-origin")
        assertTrue((normalized.getString("profileHash", null) ?: "").isNotBlank())
    }

    @Test
    fun cdnAntiWhitelistRoutingPolicyScaffoldNormalizesPolicyHints() {
        val normalized =
            VpnRuntimeLibbox.normalizeRuntimeArgs(
                JSObject().apply {
                    put("serverHost", "example.com")
                    put("transport", "xray")
                    put("engine", "sing-box")
                    put("protocol", "vless-reality")
                    put(
                        "profileJson",
                        """
                        {
                          "androidRuntime": {
                            "cdnAntiWhitelist": {
                              "enabled": true,
                              "transport": "websocket",
                              "frontHost": "edge-a.example.com",
                              "frontPath": "/odin-a",
                              "routingPolicy": {
                                "dnsQueryStrategy": "UseIP",
                                "domainStrategy": "IPIfNonMatch",
                                "domainMatcher": "hybrid",
                                "directDomainKeywords": [
                                  "keyword:vk",
                                  "keyword:mail.ru",
                                  "keyword:gosuslugi"
                                ],
                                "blockedDomainKeywords": [
                                  "keyword:max.ru"
                                ],
                                "blockSelectedFrontHost": true
                              }
                            }
                          }
                        }
                        """.trimIndent(),
                    )
                },
            )

        assertEquals("use_ip", normalized.getString("cdnRoutingDnsQueryStrategy", null))
        assertEquals("ip_if_non_match", normalized.getString("cdnRoutingDomainStrategy", null))
        assertEquals("hybrid", normalized.getString("cdnRoutingDomainMatcher", null))
        assertEquals(3, normalized.optJSONArray("cdnRoutingDirectDomainKeywords")?.length())
        assertEquals("vk", normalized.optJSONArray("cdnRoutingDirectDomainKeywords")?.optString(0))
        assertEquals("mail.ru", normalized.optJSONArray("cdnRoutingDirectDomainKeywords")?.optString(1))
        assertEquals("gosuslugi", normalized.optJSONArray("cdnRoutingDirectDomainKeywords")?.optString(2))
        assertEquals(1, normalized.optJSONArray("cdnRoutingBlockedDomainKeywords")?.length())
        assertEquals("max.ru", normalized.optJSONArray("cdnRoutingBlockedDomainKeywords")?.optString(0))
        assertTrue(normalized.getBoolean("cdnRoutingBlockSelectedFrontHost", false))
        assertEquals(3, normalized.optInt("cdnRoutingDirectRuleCount", 0))
        assertEquals(2, normalized.optInt("cdnRoutingBlockRuleCount", 0))
        assertFeature(normalized, "cdn-routing")
        assertFeature(normalized, "cdn-routing-dns:use_ip")
        assertFeature(normalized, "cdn-routing-domain-strategy:ip_if_non_match")
        assertFeature(normalized, "cdn-routing-domain-matcher:hybrid")
        assertFeature(normalized, "cdn-routing-direct:3")
        assertFeature(normalized, "cdn-routing-block:2")
        assertFeature(normalized, "cdn-routing-block-front")
    }

    @Test
    fun activeCdnConfigProjectsRoutingPolicyIntoDirectAndBlockRules() {
        val config =
            VpnRuntimeLibbox.renderCdnAntiWhitelistConfigForTesting(
                JSObject().apply {
                    put("serverHost", "example.com")
                    put("transport", "xray")
                    put("engine", "sing-box")
                    put("protocol", "vless-reality")
                    put(
                        "profileJson",
                        """
                        {
                          "stagedFallbacks": {
                            "vlessReality": {
                              "port": 443,
                              "uuid": "9425da86-1560-4f77-ac53-076a2fa7eecd",
                              "serverName": "www.cloudflare.com",
                              "publicKey": "HR2qUZNinSLuJx2-dvQNMpjEyqZ6spD-8TNzGEwuyW8",
                              "shortId": "9a3d8b86a93616a7"
                            }
                          },
                          "androidRuntime": {
                            "cdnAntiWhitelist": {
                              "enabled": true,
                              "mode": "lab",
                              "transport": "websocket",
                              "frontHost": "edge-a.example.com",
                              "connectHost": "connect-a.example.net",
                              "connectPort": 9443,
                              "frontPath": "/odin-a",
                              "routingPolicy": {
                                "directDomainKeywords": [
                                  "keyword:vk",
                                  "keyword:mail.ru"
                                ],
                                "directDomains": [
                                  "ok.ru"
                                ],
                                "blockedDomainKeywords": [
                                  "keyword:max.ru"
                                ],
                                "blockedDomains": [
                                  "max.ru"
                                ],
                                "blockSelectedFrontHost": true
                              }
                            }
                          }
                        }
                        """.trimIndent(),
                    )
                },
            )
        val parsed = JSONObject(config)
        val outbounds = parsed.getJSONArray("outbounds")
        val routeRules = parsed.getJSONObject("route").getJSONArray("rules")
        val mainOutbound = jsonArrayFindObjectWithString(outbounds, "tag", "main-out")

        assertTrue(jsonArrayContainsObjectWithString(outbounds, "tag", "block"))
        assertEquals("connect-a.example.net", mainOutbound?.getString("server") ?: "")
        assertEquals(9443, mainOutbound?.getInt("server_port") ?: 0)
        assertTrue(
            jsonArrayContainsRule(
                routeRules,
                "domain_keyword",
                "vk",
                "outbound",
                "direct",
            ),
        )
        assertTrue(
            jsonArrayContainsRule(
                routeRules,
                "domain_keyword",
                "mail.ru",
                "outbound",
                "direct",
            ),
        )
        assertTrue(
            jsonArrayContainsRule(
                routeRules,
                "domain",
                "ok.ru",
                "outbound",
                "direct",
            ),
        )
        assertTrue(
            jsonArrayContainsRule(
                routeRules,
                "domain_keyword",
                "max.ru",
                "outbound",
                "block",
            ),
        )
        assertTrue(
            jsonArrayContainsRule(
                routeRules,
                "domain",
                "edge-a.example.com",
                "outbound",
                "block",
            ),
        )
        val dns = parsed.getJSONObject("dns")
        val dnsServers = dns.getJSONArray("servers")
        val dnsRules = dns.getJSONArray("rules")
        assertTrue(jsonArrayContainsObjectWithString(dnsServers, "tag", "local-resolver"))
        assertTrue(
            jsonArrayContainsDnsRule(
                dnsRules,
                "domain_keyword",
                "vk",
                "server",
                "local-resolver",
            ),
        )
        assertTrue(
            jsonArrayContainsDnsRule(
                dnsRules,
                "domain",
                "ok.ru",
                "server",
                "local-resolver",
            ),
        )
    }

    @Test
    fun realityWhitelistHintsProfileSelectsScaffoldFamily() {
        val normalized =
            VpnRuntimeLibbox.normalizeRuntimeArgs(
                JSObject().apply {
                    put("serverHost", "example.com")
                    put("transport", "xray")
                    put("engine", "sing-box")
                    put("protocol", "vless-reality")
                    put(
                        "profileJson",
                        """
                        {
                          "androidRuntime": {
                            "reality": {
                              "mode": "stable",
                              "dnsMode": "dot",
                              "dnsServer": "8.8.8.8",
                              "dnsServerName": "dns.google"
                            },
                            "realityWhitelistHints": {
                              "enabled": true,
                              "mode": "scaffold",
                              "selection": "ordered",
                              "hints": [
                                {
                                  "serverName": "max.ru",
                                  "cidrBucket": "white-cidr-a",
                                  "source": "operator-curated",
                                  "tag": "primary-whitelist"
                                },
                                {
                                  "serverName": "pimg.mycdn.me",
                                  "cidrBucket": "white-cidr-b",
                                  "source": "operator-curated",
                                  "tag": "backup-whitelist"
                                }
                              ]
                            }
                          }
                        }
                        """.trimIndent(),
                    )
                },
            )

        assertEquals("reality-whitelist-assisted", normalized.getString("runtimeFamily", null))
        assertEquals("scaffold_only", normalized.getString("activationState", null))
        assertEquals("scaffold", normalized.getString("configMode", null))
        assertEquals("dot", normalized.getString("dnsMode", null))
        assertFalse(normalized.getBoolean("bootRestoreEnabled", true))
        assertEquals("max.ru", normalized.getString("selectedSniHint", null))
        assertEquals("white-cidr-a", normalized.getString("selectedCidrHint", null))
        assertEquals("operator-curated", normalized.getString("whitelistHintSource", null))
        assertEquals("primary-whitelist", normalized.getString("whitelistHintTag", null))
        assertFeature(normalized, "family:reality-whitelist-assisted")
        assertFeature(normalized, "activation:scaffold_only")
        assertFeature(normalized, "mode:scaffold")
        assertFeature(normalized, "whitelist-selection:ordered")
        assertFeature(normalized, "whitelist-sni:max.ru")
        assertFeature(normalized, "whitelist-cidr:white-cidr-a")
        assertFeature(normalized, "whitelist-source:operator-curated")
        assertFeature(normalized, "whitelist-tag:primary-whitelist")
        assertFeature(normalized, "whitelist-pool:2")
        assertFeature(normalized, "dns:dot")
        assertFeature(normalized, "resolver:8.8.8.8")
        assertTrue((normalized.getString("profileHash", null) ?: "").isNotBlank())
    }

    @Test
    fun realityWhitelistHintsTreatsNullCidrBucketAsMissing() {
        val normalized =
            VpnRuntimeLibbox.normalizeRuntimeArgs(
                JSObject().apply {
                    put("serverHost", "example.com")
                    put("transport", "xray")
                    put("engine", "sing-box")
                    put("protocol", "vless-reality")
                    put(
                        "profileJson",
                        """
                        {
                          "androidRuntime": {
                            "realityWhitelistHints": {
                              "enabled": true,
                              "mode": "scaffold",
                              "selection": "ordered",
                              "hints": [
                                {
                                  "serverName": "rbc.ru",
                                  "cidrBucket": null,
                                  "source": "operator-curated:white-sni.txt",
                                  "tag": "candidate-02-rbc-ru"
                                }
                              ]
                            }
                          }
                        }
                        """.trimIndent(),
                    )
                },
            )

        assertEquals("reality-whitelist-assisted", normalized.getString("runtimeFamily", null))
        assertEquals("rbc.ru", normalized.getString("selectedSniHint", null))
        assertFalse(normalized.has("selectedCidrHint"))
        assertEquals("operator-curated:white-sni.txt", normalized.getString("whitelistHintSource", null))
        assertEquals("candidate-02-rbc-ru", normalized.getString("whitelistHintTag", null))
        assertFeature(normalized, "whitelist-sni:rbc.ru")
        assertFeature(normalized, "whitelist-source:operator-curated:white-sni.txt")
        assertFeature(normalized, "whitelist-tag:candidate-02-rbc-ru")
    }

    @Test
    fun realityWhitelistHintsPreservesSourceRoundRobinSelection() {
        val normalized =
            VpnRuntimeLibbox.normalizeRuntimeArgs(
                JSObject().apply {
                    put("serverHost", "example.com")
                    put("transport", "xray")
                    put("engine", "sing-box")
                    put("protocol", "vless-reality")
                    put(
                        "profileJson",
                        """
                        {
                          "androidRuntime": {
                            "realityWhitelistHints": {
                              "enabled": true,
                              "mode": "lab",
                              "selection": "source-round-robin",
                              "hints": [
                                {
                                  "serverName": "sun6-22.userapi.com",
                                  "source": "operator-curated:community:igareck-white-sni.txt",
                                  "tag": "candidate-01-sun6-22-userapi-com"
                                }
                              ]
                            }
                          }
                        }
                        """.trimIndent(),
                    )
                },
            )

        assertEquals("source-round-robin", normalized.getString("whitelistHintSelection", null))
        assertFeature(normalized, "whitelist-selection:source-round-robin")
    }

    @Test
    fun realityWhitelistHintsLabModeBecomesActive() {
        val normalized =
            VpnRuntimeLibbox.normalizeRuntimeArgs(
                JSObject().apply {
                    put("serverHost", "example.com")
                    put("transport", "xray")
                    put("engine", "sing-box")
                    put("protocol", "vless-reality")
                    put(
                        "profileJson",
                        """
                        {
                          "androidRuntime": {
                            "reality": {
                              "mode": "stable"
                            },
                            "realityWhitelistHints": {
                              "enabled": true,
                              "mode": "lab",
                              "selection": "ordered",
                              "hints": [
                                {
                                  "serverName": "duma.gov.ru",
                                  "source": "operator-curated:community:hxehex-whitelist.txt",
                                  "tag": "candidate-02-duma-gov-ru"
                                }
                              ]
                            }
                          }
                        }
                        """.trimIndent(),
                    )
                },
            )

        assertEquals("reality-whitelist-assisted", normalized.getString("runtimeFamily", null))
        assertEquals("active", normalized.getString("activationState", null))
        assertEquals("lab", normalized.getString("configMode", null))
        assertFalse(normalized.getBoolean("bootRestoreEnabled", true))
        assertEquals("duma.gov.ru", normalized.getString("selectedSniHint", null))
        assertEquals(
            "operator-curated:community:hxehex-whitelist.txt",
            normalized.getString("whitelistHintSource", null),
        )
        assertEquals("candidate-02-duma-gov-ru", normalized.getString("whitelistHintTag", null))
        assertFeature(normalized, "family:reality-whitelist-assisted")
        assertFeature(normalized, "activation:active")
        assertFeature(normalized, "mode:lab")
        assertFeature(normalized, "whitelist-sni:duma.gov.ru")
        assertTrue((normalized.getString("profileHash", null) ?: "").isNotBlank())
    }

    @Test
    fun realityVpsLabTcpModeBecomesActive() {
        val normalized =
            VpnRuntimeLibbox.normalizeRuntimeArgs(
                JSObject().apply {
                    put("serverHost", "95.81.120.226")
                    put("transport", "xray")
                    put("engine", "sing-box")
                    put("protocol", "vless-reality")
                    put(
                        "profileJson",
                        """
                        {
                          "stagedFallbacks": {
                            "vlessReality": {
                              "port": 443,
                              "uuid": "9425da86-1560-4f77-ac53-076a2fa7eecd",
                              "flow": "xtls-rprx-vision",
                              "serverName": "www.cloudflare.com",
                              "publicKey": "HR2qUZNinSLuJx2-dvQNMpjEyqZ6spD-8TNzGEwuyW8",
                              "shortId": "9a3d8b86a93616a7"
                            }
                          },
                          "androidRuntime": {
                            "realityVpsLab": {
                              "enabled": true,
                              "mode": "lab",
                              "serverName": "pimg.mycdn.me",
                              "port": 10443,
                              "transport": "tcp",
                              "flow": "xtls-rprx-vision",
                              "fingerprint": "chrome",
                              "source": "operator-curated:vps-lab",
                              "tag": "reality-lab-pimg-mycdn-me-tcp"
                            }
                          }
                        }
                        """.trimIndent(),
                    )
                },
            )

        assertEquals("reality-vps-lab", normalized.getString("runtimeFamily", null))
        assertEquals("active", normalized.getString("activationState", null))
        assertEquals("lab", normalized.getString("configMode", null))
        assertEquals("pimg.mycdn.me", normalized.getString("selectedSniHint", null))
        assertEquals(10443, normalized.optInt("vpsRealityPort", 0))
        assertEquals("tcp", normalized.getString("vpsRealityTransport", null))
        assertEquals("xtls-rprx-vision", normalized.getString("vpsRealityFlow", null))
        assertEquals("chrome", normalized.getString("vpsRealityFingerprint", null))
        assertEquals("operator-curated:vps-lab", normalized.getString("whitelistHintSource", null))
        assertEquals("reality-lab-pimg-mycdn-me-tcp", normalized.getString("whitelistHintTag", null))
        assertFeature(normalized, "family:reality-vps-lab")
        assertFeature(normalized, "activation:active")
        assertFeature(normalized, "reality-vps-transport:tcp")
        assertFeature(normalized, "reality-vps-port:10443")
        assertTrue((normalized.getString("profileHash", null) ?: "").isNotBlank())
    }

    @Test
    fun realityVpsLabGrpcModeDefaultsToScaffoldAndOmitsFlow() {
        val normalized =
            VpnRuntimeLibbox.normalizeRuntimeArgs(
                JSObject().apply {
                    put("serverHost", "95.81.120.226")
                    put("transport", "xray")
                    put("engine", "sing-box")
                    put("protocol", "vless-reality")
                    put(
                        "profileJson",
                        """
                        {
                          "stagedFallbacks": {
                            "vlessReality": {
                              "port": 443,
                              "uuid": "9425da86-1560-4f77-ac53-076a2fa7eecd",
                              "flow": "xtls-rprx-vision",
                              "serverName": "www.cloudflare.com",
                              "publicKey": "HR2qUZNinSLuJx2-dvQNMpjEyqZ6spD-8TNzGEwuyW8",
                              "shortId": "9a3d8b86a93616a7"
                            }
                          },
                          "androidRuntime": {
                            "realityVpsLab": {
                              "enabled": true,
                              "mode": "scaffold",
                              "serverName": "ads.x5.ru",
                              "port": 20443,
                              "transport": "grpc"
                            }
                          }
                        }
                        """.trimIndent(),
                    )
                },
            )

        assertEquals("reality-vps-lab", normalized.getString("runtimeFamily", null))
        assertEquals("scaffold_only", normalized.getString("activationState", null))
        assertEquals("scaffold", normalized.getString("configMode", null))
        assertEquals("ads.x5.ru", normalized.getString("selectedSniHint", null))
        assertEquals(20443, normalized.optInt("vpsRealityPort", 0))
        assertEquals("grpc", normalized.getString("vpsRealityTransport", null))
        assertEquals("firefox", normalized.getString("vpsRealityFingerprint", null))
        assertFalse(normalized.has("vpsRealityFlow"))
        assertFeature(normalized, "reality-vps-transport:grpc")
        assertFeature(normalized, "reality-vps-fingerprint:firefox")
    }

    @Test
    fun realityVpsLabCanSeparateConnectHostFromOriginPort() {
        val normalized =
            VpnRuntimeLibbox.normalizeRuntimeArgs(
                JSObject().apply {
                    put("serverHost", "95.81.120.226")
                    put("transport", "xray")
                    put("engine", "sing-box")
                    put("protocol", "vless-reality")
                    put(
                        "profileJson",
                        """
                        {
                          "stagedFallbacks": {
                            "vlessReality": {
                              "port": 443,
                              "uuid": "9425da86-1560-4f77-ac53-076a2fa7eecd",
                              "flow": "xtls-rprx-vision",
                              "serverName": "www.cloudflare.com",
                              "publicKey": "HR2qUZNinSLuJx2-dvQNMpjEyqZ6spD-8TNzGEwuyW8",
                              "shortId": "9a3d8b86a93616a7"
                            }
                          },
                          "androidRuntime": {
                            "realityVpsLab": {
                              "enabled": true,
                              "mode": "lab",
                              "serverName": "id.x5.ru",
                              "port": 30443,
                              "connectHost": "edge-owner.example.net",
                              "connectPort": 443,
                              "transport": "tcp",
                              "flow": "xtls-rprx-vision",
                              "fingerprint": "chrome",
                              "source": "operator-curated:vps-edge-origin",
                              "tag": "reality-edge-id-x5-ru"
                            }
                          }
                        }
                        """.trimIndent(),
                    )
                },
            )

        assertEquals("reality-vps-lab", normalized.getString("runtimeFamily", null))
        assertEquals(30443, normalized.optInt("vpsRealityPort", 0))
        assertEquals("edge-owner.example.net", normalized.getString("vpsRealityConnectHost", null))
        assertEquals(443, normalized.optInt("vpsRealityConnectPort", 0))
        assertEquals("id.x5.ru", normalized.getString("frontHost", null))
        assertEquals("edge-owner.example.net", normalized.getString("frontConnectHost", null))
        assertEquals(443, normalized.optInt("frontConnectPort", 0))
        assertFeature(normalized, "reality-vps-connect:edge-owner.example.net")
        assertFeature(normalized, "reality-vps-connect-port:443")
    }

    @Test
    fun realityVpsLabCanEnableOwnerRealityEgress() {
        val normalized =
            VpnRuntimeLibbox.normalizeRuntimeArgs(
                JSObject().apply {
                    put("serverHost", "95.81.120.226")
                    put("transport", "xray")
                    put("engine", "sing-box")
                    put("protocol", "vless-reality")
                    put(
                        "profileJson",
                        """
                        {
                          "stagedFallbacks": {
                            "vlessReality": {
                              "port": 443,
                              "uuid": "9425da86-1560-4f77-ac53-076a2fa7eecd",
                              "flow": "xtls-rprx-vision",
                              "serverName": "id.x5.ru",
                              "publicKey": "HR2qUZNinSLuJx2-dvQNMpjEyqZ6spD-8TNzGEwuyW8",
                              "shortId": "9a3d8b86a93616a7"
                            }
                          },
                          "androidRuntime": {
                            "realityVpsLab": {
                              "enabled": true,
                              "mode": "lab",
                              "serverName": "id.x5.ru",
                              "port": 443,
                              "connectHost": "217.16.17.95",
                              "connectPort": 443,
                              "transport": "tcp",
                              "flow": "xtls-rprx-vision",
                              "fingerprint": "chrome",
                              "ownerRealityEgress": true,
                              "ownerRealityBootstrap": {
                                "serverHost": "95.81.120.226",
                                "port": 52443,
                                "uuid": "fe05feb2-c88c-46bc-b809-ba9eefc5e6ee",
                                "flow": "xtls-rprx-vision",
                                "serverName": "www.cloudflare.com",
                                "publicKey": "EwRrvp8PKSyz5Fb2tgXG-4uv1UJfQw65yRTvoH36aw4",
                                "shortId": "2d2812af9d8e4cf4"
                              }
                            }
                          }
                        }
                        """.trimIndent(),
                    )
                },
            )

        assertEquals("reality-vps-lab", normalized.getString("runtimeFamily", null))
        assertTrue(normalized.getBoolean("vpsRealityOwnerEgress", false))
        assertFeature(normalized, "reality-vps-owner-egress:on")
    }

    @Test
    fun cdnAntiWhitelistTakesPrecedenceOverRealityWhitelistHints() {
        val normalized =
            VpnRuntimeLibbox.normalizeRuntimeArgs(
                JSObject().apply {
                    put("serverHost", "example.com")
                    put("transport", "xray")
                    put("engine", "sing-box")
                    put("protocol", "vless-reality")
                    put(
                        "profileJson",
                        """
                        {
                          "androidRuntime": {
                            "cdnAntiWhitelist": {
                              "enabled": true,
                              "transport": "xhttp",
                              "frontPool": [
                                {
                                  "host": "edge-a.example.com"
                                }
                              ]
                            },
                            "realityWhitelistHints": {
                              "enabled": true,
                              "hints": [
                                {
                                  "serverName": "max.ru",
                                  "cidrBucket": "white-cidr-a"
                                }
                              ]
                            }
                          }
                        }
                        """.trimIndent(),
                    )
                },
            )

        assertEquals("cdn-anti-whitelist", normalized.getString("runtimeFamily", null))
        assertFalse(normalized.has("selectedSniHint"))
    }

    @Test
    fun cdnAntiWhitelistWebsocketLabModeActivatesHiddenFamily() {
        val normalized =
            VpnRuntimeLibbox.normalizeRuntimeArgs(
                JSObject().apply {
                    put("serverHost", "example.com")
                    put("transport", "xray")
                    put("engine", "sing-box")
                    put("protocol", "vless-reality")
                    put(
                        "profileJson",
                        """
                        {
                          "stagedFallbacks": {
                            "vlessReality": {
                              "port": 443,
                              "uuid": "9425da86-1560-4f77-ac53-076a2fa7eecd",
                              "serverName": "www.cloudflare.com",
                              "publicKey": "HR2qUZNinSLuJx2-dvQNMpjEyqZ6spD-8TNzGEwuyW8",
                              "shortId": "9a3d8b86a93616a7"
                            }
                          },
                          "androidRuntime": {
                            "cdnAntiWhitelist": {
                              "enabled": true,
                              "mode": "lab",
                              "provider": "cloudflare",
                              "transport": "websocket",
                              "frontSelection": "ordered",
                              "frontPool": [
                                {
                                  "host": "edge-a.example.com",
                                  "port": 443,
                                  "path": "/odin-a",
                                  "tlsServerName": "front-a.example.com",
                                  "hostHeader": "allowed-a.example.com",
                                  "provider": "cloudflare",
                                  "tag": "primary-whitelist"
                                }
                              ],
                              "origin": {
                                "host": "origin.example.com",
                                "port": 443,
                                "scheme": "https",
                                "path": "/odin-origin"
                              }
                            }
                          }
                        }
                        """.trimIndent(),
                    )
                },
            )

        assertEquals("cdn-anti-whitelist", normalized.getString("runtimeFamily", null))
        assertEquals("active", normalized.getString("activationState", null))
        assertEquals("lab", normalized.getString("configMode", null))
        assertEquals("websocket", normalized.getString("cdnTransport", null))
        assertEquals("edge-a.example.com", normalized.getString("cdnFrontHost", null))
        assertEquals("/odin-a", normalized.getString("cdnFrontPath", null))
        assertFeature(normalized, "family:cdn-anti-whitelist")
        assertFeature(normalized, "activation:active")
        assertFeature(normalized, "mode:lab")
        assertFeature(normalized, "cdn-transport:websocket")
        assertTrue((normalized.getString("profileHash", null) ?: "").isNotBlank())
    }

    @Test
    fun cdnAntiWhitelistLabModeStaysScaffoldedForNonWebsocketTransport() {
        val normalized =
            VpnRuntimeLibbox.normalizeRuntimeArgs(
                JSObject().apply {
                    put("serverHost", "example.com")
                    put("transport", "xray")
                    put("engine", "sing-box")
                    put("protocol", "vless-reality")
                    put(
                        "profileJson",
                        """
                        {
                          "stagedFallbacks": {
                            "vlessReality": {
                              "port": 443,
                              "uuid": "9425da86-1560-4f77-ac53-076a2fa7eecd",
                              "serverName": "www.cloudflare.com",
                              "publicKey": "HR2qUZNinSLuJx2-dvQNMpjEyqZ6spD-8TNzGEwuyW8",
                              "shortId": "9a3d8b86a93616a7"
                            }
                          },
                          "androidRuntime": {
                            "cdnAntiWhitelist": {
                              "enabled": true,
                              "mode": "lab",
                              "transport": "xhttp",
                              "frontPool": [
                                {
                                  "host": "edge-a.example.com"
                                }
                              ]
                            }
                          }
                        }
                        """.trimIndent(),
                    )
                },
            )

        assertEquals("cdn-anti-whitelist", normalized.getString("runtimeFamily", null))
        assertEquals("scaffold_only", normalized.getString("activationState", null))
        assertEquals("lab", normalized.getString("configMode", null))
        assertEquals("xhttp", normalized.getString("cdnTransport", null))
    }

    @Test
    fun requestMatchingIncludesProfileHashAndConfigMode() {
        val snapshot =
            TunnelSnapshot(
                status = "running",
                serverHost = "example.com",
                transport = "xray",
                engine = "sing-box",
                protocol = "vless-reality",
                runtimeFamily = "direct-reality",
                activationState = "active",
                vkLink = null,
                profileHash = "hash-a",
                configMode = "stable",
            )

        val identical =
            JSObject().apply {
                put("serverHost", "example.com")
                put("transport", "xray")
                put("engine", "sing-box")
                put("protocol", "vless-reality")
                put("runtimeFamily", "direct-reality")
                put("activationState", "active")
                put("profileHash", "hash-a")
                put("configMode", "stable")
            }
        val differentMode =
            JSObject(identical.toString()).apply {
                put("configMode", "experimental")
            }
        val differentHash =
            JSObject(identical.toString()).apply {
                put("profileHash", "hash-b")
            }

        assertTrue(matchesTunnelRequest(snapshot, identical))
        assertFalse(matchesTunnelRequest(snapshot, differentMode))
        assertFalse(matchesTunnelRequest(snapshot, differentHash))
    }

    @Test
    fun requestMatchingTreatsMissingRuntimeFamilyAsLegacyDirectReality() {
        val snapshot =
            TunnelSnapshot(
                status = "running",
                serverHost = "example.com",
                transport = "xray",
                engine = "sing-box",
                protocol = "vless-reality",
                profileHash = "hash-a",
                configMode = "stable",
            )
        val normalized =
            JSObject().apply {
                put("serverHost", "example.com")
                put("transport", "xray")
                put("engine", "sing-box")
                put("protocol", "vless-reality")
                put("runtimeFamily", "direct-reality")
                put("activationState", "active")
                put("profileHash", "hash-a")
                put("configMode", "stable")
            }

        assertTrue(matchesTunnelRequest(snapshot, normalized))
    }

    @Test
    fun startSnapshotInitializesFreshRecoverySessionCounters() {
        val snapshot =
            startSnapshotFromArgs(
                JSObject().apply {
                    put("serverHost", "example.com")
                    put("transport", "xray")
                    put("engine", "sing-box")
                    put("protocol", "vless-reality")
                    put("runtimeFamily", "direct-reality")
                    put("activationState", "active")
                    put("startSource", "app")
                    put("profileHash", "hash-a")
                    put("configMode", "stable")
                },
                "Preparing runtime",
            )

        assertEquals("starting", snapshot.status)
        assertEquals(0, snapshot.networkChangeCount)
        assertEquals(0, snapshot.sessionNetworkChangeCount)
        assertEquals(0, snapshot.reloadCount)
        assertEquals(0, snapshot.sessionReloadCount)
        assertTrue((snapshot.sessionId ?: "").isNotBlank())
        assertTrue((snapshot.sessionStartedAt ?: "").isNotBlank())
    }

    @Test
    fun startSnapshotCapturesCdnRoutingDiagnostics() {
        val snapshot =
            startSnapshotFromArgs(
                JSObject().apply {
                    put("serverHost", "example.com")
                    put("transport", "xray")
                    put("engine", "sing-box")
                    put("protocol", "vless-reality")
                    put("runtimeFamily", "cdn-anti-whitelist")
                    put("activationState", "lab")
                    put("frontHost", "edge-a.example.com")
                    put("frontConnectHost", "connect-a.example.net")
                    put("frontConnectPort", 9443)
                    put("cdnRoutingDnsQueryStrategy", "use_ip")
                    put("cdnRoutingDomainStrategy", "ip_if_non_match")
                    put("cdnRoutingDomainMatcher", "hybrid")
                    put("cdnRoutingDirectRuleCount", 21)
                    put("cdnRoutingBlockRuleCount", 2)
                    put("cdnRoutingBlockSelectedFrontHost", true)
                    put("cdnDnsLocalResolverEnabled", true)
                    put("profileHash", "cdn-hash-a")
                    put("configMode", "lab")
                },
                "Preparing runtime",
            )

        assertEquals("connect-a.example.net", snapshot.frontConnectHost)
        assertEquals(9443, snapshot.frontConnectPort)
        assertEquals("use_ip", snapshot.cdnRoutingDnsQueryStrategy)
        assertEquals("ip_if_non_match", snapshot.cdnRoutingDomainStrategy)
        assertEquals("hybrid", snapshot.cdnRoutingDomainMatcher)
        assertEquals(21, snapshot.cdnRoutingDirectRuleCount)
        assertEquals(2, snapshot.cdnRoutingBlockRuleCount)
        assertTrue(snapshot.cdnRoutingBlockSelectedFrontHost ?: false)
        assertTrue(snapshot.cdnDnsLocalResolverEnabled ?: false)
    }

    @Test
    fun runningSnapshotsNormalizePreRunningStartupStages() {
        assertEquals("running", normalizeRunningStartupStage("running", "socks_ready"))
        assertEquals("running", normalizeRunningStartupStage("running", "service_started"))
        assertEquals("running", normalizeRunningStartupStage("running", null))
        assertEquals("waiting_for_relay", normalizeRunningStartupStage("starting", "waiting_for_relay"))
    }

    @Test
    fun repairRuntimeSnapshotMarksDeadRunningStateAsStopped() {
        val repaired =
            repairRuntimeSnapshotStateForTest(
                snapshot =
                    TunnelSnapshot(
                        status = "running",
                        runtimeFamily = "reality-vps-lab",
                        lastNetworkEvent = "tun:established",
                        logTail = listOf("Android VPN runtime is active."),
                    ),
                serviceRunning = false,
                recoveredSocksAddress = "127.0.0.1:58371",
                socksReachable = false,
            )

        assertEquals("stopped", repaired.status)
        assertEquals(null, repaired.socksAddress)
        assertEquals("stale:service-missing", repaired.lastNetworkEvent)
        assertEquals("stopped", repaired.lastStartupStage)
        assertTrue(repaired.logTail.last().contains("stale", ignoreCase = true))
    }

    @Test
    fun repairRuntimeSnapshotRecoversMissingSocksForHealthyService() {
        val repaired =
            repairRuntimeSnapshotStateForTest(
                snapshot =
                    TunnelSnapshot(
                        status = "running",
                        runtimeFamily = "reality-vps-lab",
                        logTail = listOf("Android VPN runtime is active."),
                    ),
                serviceRunning = true,
                recoveredSocksAddress = "127.0.0.1:58371",
                socksReachable = true,
            )

        assertEquals("running", repaired.status)
        assertEquals("127.0.0.1:58371", repaired.socksAddress)
    }

    @Test
    fun persistedRealityRestoreRequestRefreshesDerivedFields() {
        val normalized =
            normalizePersistedRestoreRequest(
                JSObject().apply {
                    put("serverHost", "example.com")
                    put("transport", "xray")
                    put("engine", "sing-box")
                    put("protocol", "vless-reality")
                    put("profileHash", "stale-hash")
                    put(
                        "profileJson",
                        """
                        {
                          "stagedFallbacks": {
                            "vlessReality": {
                              "port": 443,
                              "uuid": "9425da86-1560-4f77-ac53-076a2fa7eecd",
                              "serverName": "www.cloudflare.com",
                              "publicKey": "HR2qUZNinSLuJx2-dvQNMpjEyqZ6spD-8TNzGEwuyW8",
                              "shortId": "9a3d8b86a93616a7"
                            }
                          },
                          "androidRuntime": {
                            "reality": {
                              "networkReloadOnChange": true,
                              "networkReloadDebounceMs": 1500
                            }
                          }
                        }
                        """.trimIndent(),
                    )
                },
            )

        assertNotEquals("stale-hash", normalized.getString("profileHash", null))
        assertFeature(normalized, "net-reload:1500ms")
    }

    @Test
    fun persistedRestoreRequestDropsTransientSessionFields() {
        val normalized =
            normalizePersistedRestoreRequest(
                JSObject().apply {
                    put("serverHost", "example.com")
                    put("transport", "xray")
                    put("engine", "sing-box")
                    put("protocol", "vless-reality")
                    put("startSource", "boot_restore")
                    put("socksAddress", "127.0.0.1:1080")
                    put("lastNetworkEvent", "startup:running")
                    put("sessionId", "session-1")
                    put("networkChangeCount", 12)
                    put(
                        "lastTest",
                        JSObject().apply {
                            put("ok", true)
                            put("status", "passed")
                            put("url", "https://example.com")
                        },
                    )
                    put(
                        "profileJson",
                        """
                        {
                          "androidRuntime": {
                            "reality": {
                              "mode": "stable"
                            }
                          }
                        }
                        """.trimIndent(),
                    )
                },
            )

        assertFalse(normalized.has("startSource"))
        assertFalse(normalized.has("socksAddress"))
        assertFalse(normalized.has("lastNetworkEvent"))
        assertFalse(normalized.has("sessionId"))
        assertFalse(normalized.has("networkChangeCount"))
        assertFalse(normalized.has("lastTest"))
    }

    @Test
    fun attemptedRequestPreservesStartSourceForScaffoldDiagnostics() {
        val normalized =
            normalizePersistedAttemptRequest(
                JSObject().apply {
                    put("serverHost", "example.com")
                    put("transport", "xray")
                    put("engine", "sing-box")
                    put("protocol", "vless-reality")
                    put("startSource", "app")
                    put(
                        "profileJson",
                        """
                        {
                          "androidRuntime": {
                            "realityWhitelistHints": {
                              "enabled": true,
                              "mode": "scaffold",
                              "hints": [
                                {
                                  "serverName": "max.ru",
                                  "cidrBucket": "cidr-max",
                                  "source": "operator-curated",
                                  "tag": "candidate-max-ru"
                                }
                              ]
                            }
                          }
                        }
                        """.trimIndent(),
                    )
                },
            )

        assertEquals("app", normalized.getString("startSource", null))
        assertEquals("reality-whitelist-assisted", normalized.getString("runtimeFamily", null))
        assertEquals("scaffold_only", normalized.getString("activationState", null))
        assertEquals("max.ru", normalized.getString("selectedSniHint", null))
    }

    @Test
    fun attemptedRequestStillDropsTransientRuntimeFields() {
        val normalized =
            normalizePersistedAttemptRequest(
                JSObject().apply {
                    put("serverHost", "example.com")
                    put("transport", "xray")
                    put("engine", "sing-box")
                    put("protocol", "vless-reality")
                    put("startSource", "app")
                    put("socksAddress", "127.0.0.1:1080")
                    put("lastNetworkEvent", "startup:running")
                    put("sessionId", "session-1")
                    put("networkChangeCount", 12)
                },
            )

        assertEquals("app", normalized.getString("startSource", null))
        assertFalse(normalized.has("socksAddress"))
        assertFalse(normalized.has("lastNetworkEvent"))
        assertFalse(normalized.has("sessionId"))
        assertFalse(normalized.has("networkChangeCount"))
    }

    @Test
    fun attemptedRequestSelectionPrefersCredentialCopyOverBootRestoreBias() {
        val selected =
            selectPreferredAttemptedRequest(
                JSObject().apply {
                    put("runtimeFamily", "reality-whitelist-assisted")
                    put("bootRestoreEnabled", false)
                },
                JSObject().apply {
                    put("runtimeFamily", "direct-reality")
                    put("bootRestoreEnabled", true)
                },
            )

        assertEquals("reality-whitelist-assisted", selected?.getString("runtimeFamily", null))
        assertFalse(selected?.getBoolean("bootRestoreEnabled", true) ?: true)
    }

    @Test
    fun profileHashChangesWhenRealityHardeningOptionsChange() {
        val stable =
            VpnRuntimeLibbox.normalizeRuntimeArgs(
                JSObject().apply {
                    put("serverHost", "example.com")
                    put("transport", "xray")
                    put("engine", "sing-box")
                    put("protocol", "vless-reality")
                    put(
                        "profileJson",
                        """
                        {
                          "androidRuntime": {
                            "reality": {
                              "mode": "stable",
                              "dnsMode": "udp",
                              "allowPrivateNetworkBypass": true
                            }
                          }
                        }
                        """.trimIndent(),
                    )
                },
            )
        val hardened =
            JSObject(stable.toString()).apply {
                put("profileJson", """{"androidRuntime":{"reality":{"mode":"experimental","dnsMode":"dot","allowPrivateNetworkBypass":false}}}""")
            }.let(VpnRuntimeLibbox::normalizeRuntimeArgs)

        assertNotEquals(stable.getString("profileHash", null), hardened.getString("profileHash", null))
    }

    @Test
    fun profileHashChangesWhenSelectivePrivateBypassCidrsChange() {
        val conservative =
            VpnRuntimeLibbox.normalizeRuntimeArgs(
                JSObject().apply {
                    put("serverHost", "example.com")
                    put("transport", "xray")
                    put("engine", "sing-box")
                    put("protocol", "vless-reality")
                    put(
                        "profileJson",
                        """
                        {
                          "androidRuntime": {
                            "reality": {
                              "privateBypassCidrs": [
                                "10.0.0.0/8",
                                "192.168.0.0/16"
                              ]
                            }
                          }
                        }
                        """.trimIndent(),
                    )
                },
            )
        val tighter =
            VpnRuntimeLibbox.normalizeRuntimeArgs(
                JSObject().apply {
                    put("serverHost", "example.com")
                    put("transport", "xray")
                    put("engine", "sing-box")
                    put("protocol", "vless-reality")
                    put(
                        "profileJson",
                        """
                        {
                          "androidRuntime": {
                            "reality": {
                              "privateBypassCidrs": [
                                "192.168.0.0/16",
                                "169.254.0.0/16"
                              ]
                            }
                          }
                        }
                        """.trimIndent(),
                    )
                },
            )

        assertNotEquals(conservative.getString("profileHash", null), tighter.getString("profileHash", null))
    }

    @Test
    fun stableProfileHashIgnoresDisabledHiddenOverrideDatasets() {
        val first =
            VpnRuntimeLibbox.normalizeRuntimeArgs(
                JSObject().apply {
                    put("serverHost", "example.com")
                    put("transport", "xray")
                    put("engine", "sing-box")
                    put("protocol", "vless-reality")
                    put(
                        "profileJson",
                        """
                        {
                          "androidRuntime": {
                            "reality": {
                              "mode": "stable"
                            },
                            "cdnAntiWhitelist": {
                              "enabled": false,
                              "frontHost": "edge-a.example.com",
                              "frontPath": "/odin-a",
                              "routingPolicy": {
                                "dnsQueryStrategy": "UseIP",
                                "directDomainKeywords": [
                                  "keyword:vk",
                                  "keyword:ozon"
                                ],
                                "blockSelectedFrontHost": true
                              }
                            },
                            "realityWhitelistHints": {
                              "enabled": false,
                              "hints": [
                                {
                                  "serverName": "max.ru",
                                  "cidrBucket": "white-cidr-a"
                                }
                              ]
                            }
                          }
                        }
                        """.trimIndent(),
                    )
                },
            )
        val second =
            VpnRuntimeLibbox.normalizeRuntimeArgs(
                JSObject().apply {
                    put("serverHost", "example.com")
                    put("transport", "xray")
                    put("engine", "sing-box")
                    put("protocol", "vless-reality")
                    put(
                        "profileJson",
                        """
                        {
                          "androidRuntime": {
                            "reality": {
                              "mode": "stable"
                            },
                            "cdnAntiWhitelist": {
                              "enabled": false,
                              "frontHost": "edge-b.example.com",
                              "frontPath": "/odin-b",
                              "routingPolicy": {
                                "dnsQueryStrategy": "auto",
                                "directDomainKeywords": [
                                  "keyword:tinkoff"
                                ],
                                "blockSelectedFrontHost": false
                              }
                            },
                            "realityWhitelistHints": {
                              "enabled": false,
                              "hints": [
                                {
                                  "serverName": "pimg.mycdn.me",
                                  "cidrBucket": "white-cidr-b"
                                }
                              ]
                            }
                          }
                        }
                        """.trimIndent(),
                    )
                },
            )

        assertEquals("direct-reality", first.getString("runtimeFamily", null))
        assertEquals("direct-reality", second.getString("runtimeFamily", null))
        assertEquals(first.getString("profileHash", null), second.getString("profileHash", null))
    }

    @Test
    fun profileHashChangesWhenCdnScaffoldOptionsChange() {
        val first =
            VpnRuntimeLibbox.normalizeRuntimeArgs(
                JSObject().apply {
                    put("serverHost", "example.com")
                    put("transport", "xray")
                    put("engine", "sing-box")
                    put("protocol", "vless-reality")
                    put(
                        "profileJson",
                        """
                        {
                          "stagedFallbacks": {
                            "vlessReality": {
                              "port": 443,
                              "uuid": "9425da86-1560-4f77-ac53-076a2fa7eecd",
                              "serverName": "www.cloudflare.com",
                              "publicKey": "HR2qUZNinSLuJx2-dvQNMpjEyqZ6spD-8TNzGEwuyW8",
                              "shortId": "9a3d8b86a93616a7"
                            }
                          },
                          "androidRuntime": {
                            "cdnAntiWhitelist": {
                              "enabled": true,
                              "frontHost": "edge-a.example.com",
                              "frontPath": "/odin-a"
                            }
                          }
                        }
                        """.trimIndent(),
                    )
                },
            )
        val second =
            VpnRuntimeLibbox.normalizeRuntimeArgs(
                JSObject().apply {
                    put("serverHost", "example.com")
                    put("transport", "xray")
                    put("engine", "sing-box")
                    put("protocol", "vless-reality")
                    put(
                        "profileJson",
                        """
                        {
                          "stagedFallbacks": {
                            "vlessReality": {
                              "port": 443,
                              "uuid": "9425da86-1560-4f77-ac53-076a2fa7eecd",
                              "serverName": "www.cloudflare.com",
                              "publicKey": "HR2qUZNinSLuJx2-dvQNMpjEyqZ6spD-8TNzGEwuyW8",
                              "shortId": "9a3d8b86a93616a7"
                            }
                          },
                          "androidRuntime": {
                            "cdnAntiWhitelist": {
                              "enabled": true,
                              "frontHost": "edge-b.example.com",
                              "frontPath": "/odin-b"
                            }
                          }
                        }
                        """.trimIndent(),
                    )
                },
            )

        assertNotEquals(first.getString("profileHash", null), second.getString("profileHash", null))
    }

    @Test
    fun profileHashChangesWhenCdnConnectTargetChanges() {
        val first =
            VpnRuntimeLibbox.normalizeRuntimeArgs(
                JSObject().apply {
                    put("serverHost", "example.com")
                    put("transport", "xray")
                    put("engine", "sing-box")
                    put("protocol", "vless-reality")
                    put(
                        "profileJson",
                        """
                        {
                          "androidRuntime": {
                            "cdnAntiWhitelist": {
                              "enabled": true,
                              "frontHost": "edge-a.example.com",
                              "frontPath": "/odin-a",
                              "connectHost": "connect-a.example.net",
                              "connectPort": 9443
                            }
                          }
                        }
                        """.trimIndent(),
                    )
                },
            )
        val second =
            VpnRuntimeLibbox.normalizeRuntimeArgs(
                JSObject().apply {
                    put("serverHost", "example.com")
                    put("transport", "xray")
                    put("engine", "sing-box")
                    put("protocol", "vless-reality")
                    put(
                        "profileJson",
                        """
                        {
                          "androidRuntime": {
                            "cdnAntiWhitelist": {
                              "enabled": true,
                              "frontHost": "edge-a.example.com",
                              "frontPath": "/odin-a",
                              "connectHost": "connect-b.example.net",
                              "connectPort": 10443
                            }
                          }
                        }
                        """.trimIndent(),
                    )
                },
            )

        assertNotEquals(first.getString("profileHash", null), second.getString("profileHash", null))
    }

    @Test
    fun profileHashChangesWhenCdnRoutingPolicyChanges() {
        val first =
            VpnRuntimeLibbox.normalizeRuntimeArgs(
                JSObject().apply {
                    put("serverHost", "example.com")
                    put("transport", "xray")
                    put("engine", "sing-box")
                    put("protocol", "vless-reality")
                    put(
                        "profileJson",
                        """
                        {
                          "androidRuntime": {
                            "cdnAntiWhitelist": {
                              "enabled": true,
                              "frontHost": "edge-a.example.com",
                              "frontPath": "/odin-a",
                              "routingPolicy": {
                                "dnsQueryStrategy": "UseIP",
                                "directDomainKeywords": [
                                  "keyword:vk"
                                ],
                                "blockSelectedFrontHost": true
                              }
                            }
                          }
                        }
                        """.trimIndent(),
                    )
                },
            )
        val second =
            VpnRuntimeLibbox.normalizeRuntimeArgs(
                JSObject().apply {
                    put("serverHost", "example.com")
                    put("transport", "xray")
                    put("engine", "sing-box")
                    put("protocol", "vless-reality")
                    put(
                        "profileJson",
                        """
                        {
                          "androidRuntime": {
                            "cdnAntiWhitelist": {
                              "enabled": true,
                              "frontHost": "edge-a.example.com",
                              "frontPath": "/odin-a",
                              "routingPolicy": {
                                "dnsQueryStrategy": "UseIP",
                                "directDomainKeywords": [
                                  "keyword:ozon"
                                ],
                                "blockSelectedFrontHost": false
                              }
                            }
                          }
                        }
                        """.trimIndent(),
                    )
                },
            )

        assertNotEquals(first.getString("profileHash", null), second.getString("profileHash", null))
    }

    @Test
    fun profileHashChangesWhenRealityWhitelistHintsChange() {
        val first =
            VpnRuntimeLibbox.normalizeRuntimeArgs(
                JSObject().apply {
                    put("serverHost", "example.com")
                    put("transport", "xray")
                    put("engine", "sing-box")
                    put("protocol", "vless-reality")
                    put(
                        "profileJson",
                        """
                        {
                          "androidRuntime": {
                            "realityWhitelistHints": {
                              "enabled": true,
                              "hints": [
                                {
                                  "serverName": "max.ru",
                                  "cidrBucket": "white-cidr-a"
                                }
                              ]
                            }
                          }
                        }
                        """.trimIndent(),
                    )
                },
            )
        val second =
            VpnRuntimeLibbox.normalizeRuntimeArgs(
                JSObject().apply {
                    put("serverHost", "example.com")
                    put("transport", "xray")
                    put("engine", "sing-box")
                    put("protocol", "vless-reality")
                    put(
                        "profileJson",
                        """
                        {
                          "androidRuntime": {
                            "realityWhitelistHints": {
                              "enabled": true,
                              "hints": [
                                {
                                  "serverName": "pimg.mycdn.me",
                                  "cidrBucket": "white-cidr-b"
                                }
                              ]
                            }
                          }
                        }
                        """.trimIndent(),
                    )
                },
            )

        assertNotEquals(first.getString("profileHash", null), second.getString("profileHash", null))
    }

    @Test
    fun networkReloadDebounceIsClampedToSafeBounds() {
        val normalizedLow =
            VpnRuntimeLibbox.normalizeRuntimeArgs(
                JSObject().apply {
                    put("serverHost", "example.com")
                    put("transport", "xray")
                    put("engine", "sing-box")
                    put("protocol", "vless-reality")
                    put(
                        "profileJson",
                        """
                        {
                          "androidRuntime": {
                            "reality": {
                              "networkReloadOnChange": true,
                              "networkReloadDebounceMs": 10
                            }
                          }
                        }
                        """.trimIndent(),
                    )
                },
            )
        val normalizedHigh =
            VpnRuntimeLibbox.normalizeRuntimeArgs(
                JSObject().apply {
                    put("serverHost", "example.com")
                    put("transport", "xray")
                    put("engine", "sing-box")
                    put("protocol", "vless-reality")
                    put(
                        "profileJson",
                        """
                        {
                          "androidRuntime": {
                            "reality": {
                              "networkReloadOnChange": true,
                              "networkReloadDebounceMs": 12000
                            }
                          }
                        }
                        """.trimIndent(),
                    )
                },
            )

        assertEquals(250L, normalizedLow.optLong("networkReloadDebounceMs", 0L))
        assertEquals(5000L, normalizedHigh.optLong("networkReloadDebounceMs", 0L))
    }

    @Test
    fun duplicateUnderlyingInterfaceCallbacksAreIgnoredForReloadPurposes() {
        assertFalse(
            shouldProcessUnderlyingInterfaceUpdate(
                previousNetworkHandle = 102L,
                previousInterfaceName = "wlan0",
                currentNetworkHandle = 102L,
                currentInterfaceName = "wlan0",
                reason = "link-properties",
            ),
        )
        assertFalse(
            shouldProcessUnderlyingInterfaceUpdate(
                previousNetworkHandle = 102L,
                previousInterfaceName = "wlan0",
                currentNetworkHandle = 102L,
                currentInterfaceName = "wlan0",
                reason = "capabilities",
            ),
        )
        assertTrue(
            shouldProcessUnderlyingInterfaceUpdate(
                previousNetworkHandle = 102L,
                previousInterfaceName = "wlan0",
                currentNetworkHandle = 118L,
                currentInterfaceName = "rmnet_data2",
                reason = "available",
            ),
        )
        assertTrue(
            shouldProcessUnderlyingInterfaceUpdate(
                previousNetworkHandle = 102L,
                previousInterfaceName = "wlan0",
                currentNetworkHandle = 102L,
                currentInterfaceName = "wlan0",
                reason = "initial",
            ),
        )
    }

    @Test
    fun dnsStrategyFallsBackToPreferIpv4ForUnknownValues() {
        val normalized =
            VpnRuntimeLibbox.normalizeRuntimeArgs(
                JSObject().apply {
                    put("serverHost", "example.com")
                    put("transport", "xray")
                    put("engine", "sing-box")
                    put("protocol", "vless-reality")
                    put(
                        "profileJson",
                        """
                        {
                          "androidRuntime": {
                            "reality": {
                              "dnsStrategy": "something-weird"
                            }
                          }
                        }
                        """.trimIndent(),
                    )
                },
            )

        assertEquals("prefer_ipv4", normalized.getString("dnsStrategy", null))
    }

    @Test
    fun persistedHiddenRealityOverridesCanBeMergedIntoCompatibleAppStart() {
        val previous =
            JSObject().apply {
                put("serverHost", "example.com")
                put("transport", "xray")
                put("engine", "sing-box")
                put("protocol", "vless-reality")
                put("profileSource", "owner")
                put("preserveHiddenRealityOverrides", true)
                put("debugRealityPreset", "dot-google")
                put(
                    "profileJson",
                    """
                    {
                      "androidRuntime": {
                        "reality": {
                          "mode": "stable",
                          "dnsMode": "dot",
                          "dnsServer": "8.8.8.8",
                          "dnsServerName": "dns.google"
                        }
                      }
                    }
                    """.trimIndent(),
                )
            }
        val incoming =
            JSObject().apply {
                put("serverHost", "example.com")
                put("transport", "xray")
                put("engine", "sing-box")
                put("protocol", "vless-reality")
                put("profileSource", "owner")
                put("profileJson", """{"name":"Owner"}""")
            }

        val merged = mergePersistedHiddenRuntimeOverrides(previous, incoming)
        val normalized = VpnRuntimeLibbox.normalizeRuntimeArgs(merged)

        assertEquals("dot", normalized.getString("dnsMode", null))
        assertEquals("8.8.8.8", normalized.getString("dnsServer", null))
        assertEquals("dns.google", normalized.getString("dnsServerName", null))
        assertFeature(normalized, "dns:dot")
        assertFeature(normalized, "resolver:8.8.8.8")
    }

    @Test
    fun explicitIncomingRealityOverridesWinOverPersistedHiddenPreset() {
        val previous =
            JSObject().apply {
                put("serverHost", "example.com")
                put("transport", "xray")
                put("engine", "sing-box")
                put("protocol", "vless-reality")
                put("profileSource", "owner")
                put("preserveHiddenRealityOverrides", true)
                put(
                    "profileJson",
                    """
                    {
                      "androidRuntime": {
                        "reality": {
                          "dnsMode": "dot",
                          "dnsServer": "8.8.8.8",
                          "dnsServerName": "dns.google"
                        }
                      }
                    }
                    """.trimIndent(),
                )
            }
        val incoming =
            JSObject().apply {
                put("serverHost", "example.com")
                put("transport", "xray")
                put("engine", "sing-box")
                put("protocol", "vless-reality")
                put("profileSource", "owner")
                put(
                    "profileJson",
                    """
                    {
                      "androidRuntime": {
                        "reality": {
                          "dnsMode": "udp",
                          "dnsServer": "1.1.1.1",
                          "dnsServerName": "cloudflare-dns.com"
                        }
                      }
                    }
                    """.trimIndent(),
                )
            }

        val merged = mergePersistedHiddenRuntimeOverrides(previous, incoming)
        val normalized = VpnRuntimeLibbox.normalizeRuntimeArgs(merged)

        assertEquals("udp", normalized.getString("dnsMode", null))
        assertEquals("1.1.1.1", normalized.getString("dnsServer", null))
        assertEquals("cloudflare-dns.com", normalized.getString("dnsServerName", null))
    }

    @Test
    fun persistedHiddenCdnOverridesCanBeMergedIntoCompatibleAppStart() {
        val previous =
            JSObject().apply {
                put("serverHost", "example.com")
                put("transport", "xray")
                put("engine", "sing-box")
                put("protocol", "vless-reality")
                put("profileSource", "owner")
                put("preserveHiddenRealityOverrides", true)
                put("debugRealityPreset", "cdn-scaffold")
                put(
                    "profileJson",
                    """
                    {
                      "stagedFallbacks": {
                        "vlessReality": {
                          "port": 443,
                          "uuid": "9425da86-1560-4f77-ac53-076a2fa7eecd",
                          "serverName": "www.cloudflare.com",
                          "publicKey": "HR2qUZNinSLuJx2-dvQNMpjEyqZ6spD-8TNzGEwuyW8",
                          "shortId": "9a3d8b86a93616a7"
                        }
                      },
                      "androidRuntime": {
                        "cdnAntiWhitelist": {
                          "enabled": true,
                          "provider": "cloudflare",
                          "transport": "websocket",
                          "frontHost": "edge.example.com"
                        }
                      }
                    }
                    """.trimIndent(),
                )
            }
        val incoming =
            JSObject().apply {
                put("serverHost", "example.com")
                put("transport", "xray")
                put("engine", "sing-box")
                put("protocol", "vless-reality")
                put("profileSource", "owner")
                put("profileJson", """{"name":"Owner"}""")
            }

        val merged = mergePersistedHiddenRuntimeOverrides(previous, incoming)
        val normalized = VpnRuntimeLibbox.normalizeRuntimeArgs(merged)

        assertEquals("cdn-anti-whitelist", normalized.getString("runtimeFamily", null))
        assertEquals("scaffold_only", normalized.getString("activationState", null))
        assertEquals("cloudflare", normalized.getString("cdnProvider", null))
        assertEquals("websocket", normalized.getString("cdnTransport", null))
        assertEquals("edge.example.com", normalized.getString("cdnFrontHost", null))
    }

    @Test
    fun persistedHiddenRealityWhitelistOverridesCanBeMergedIntoCompatibleAppStart() {
        val previous =
            JSObject().apply {
                put("serverHost", "example.com")
                put("transport", "xray")
                put("engine", "sing-box")
                put("protocol", "vless-reality")
                put("profileSource", "owner")
                put("preserveHiddenRealityOverrides", true)
                put("debugRealityPreset", "reality-whitelist-scaffold")
                put(
                    "profileJson",
                    """
                    {
                      "androidRuntime": {
                        "realityWhitelistHints": {
                          "enabled": true,
                          "hints": [
                            {
                              "serverName": "max.ru",
                              "cidrBucket": "white-cidr-a",
                              "source": "operator-curated",
                              "tag": "primary-whitelist"
                            }
                          ]
                        }
                      }
                    }
                    """.trimIndent(),
                )
            }
        val incoming =
            JSObject().apply {
                put("serverHost", "example.com")
                put("transport", "xray")
                put("engine", "sing-box")
                put("protocol", "vless-reality")
                put("profileSource", "owner")
                put("profileJson", """{"name":"Owner"}""")
            }

        val merged = mergePersistedHiddenRuntimeOverrides(previous, incoming)
        val normalized = VpnRuntimeLibbox.normalizeRuntimeArgs(merged)

        assertEquals("reality-whitelist-assisted", normalized.getString("runtimeFamily", null))
        assertEquals("max.ru", normalized.getString("selectedSniHint", null))
        assertEquals("white-cidr-a", normalized.getString("selectedCidrHint", null))
        assertEquals("operator-curated", normalized.getString("whitelistHintSource", null))
        assertEquals("primary-whitelist", normalized.getString("whitelistHintTag", null))
    }

    @Test
    fun classifyRuntimeFailureCodeUsesMessageAndStageHints() {
        assertEquals(
            "profile_incomplete",
            classifyRuntimeFailureCode("The VLESS + REALITY access profile is incomplete", "prepare_runtime"),
        )
        assertEquals(
            "socks_timeout",
            classifyRuntimeFailureCode("Android VPN runtime failed to start.", "socks_ready"),
        )
        assertEquals(
            "vk_bridge_failed",
            classifyRuntimeFailureCode("vk-turn-proxy Android bridge exited with code 1", "running"),
        )
        assertEquals(
            "scaffold_only",
            classifyRuntimeFailureCode("Android CDN / anti-whitelist mode is scaffolded only on this branch.", "prepare_runtime"),
        )
    }

    @Test
    fun systemRestoreAvailabilityReportsUsefulSkipReasons() {
        assertEquals("resume_ineligible", classifySystemRestoreAvailability(false, JSObject().apply { put("protocol", "vless-reality") }))
        assertEquals("missing_request", classifySystemRestoreAvailability(true, null))
        assertEquals("protocol_mismatch", classifySystemRestoreAvailability(true, JSObject().apply { put("protocol", "direct-wireguard") }))
        assertEquals("scaffold_only", classifySystemRestoreAvailability(true, JSObject().apply {
            put("protocol", "vless-reality")
            put("activationState", "scaffold_only")
        }))
        assertEquals("lab_only", classifySystemRestoreAvailability(true, JSObject().apply {
            put("protocol", "vless-reality")
            put("runtimeFamily", "cdn-anti-whitelist")
            put("activationState", "active")
            put("configMode", "lab")
        }))
        assertEquals("lab_only", classifySystemRestoreAvailability(true, JSObject().apply {
            put("protocol", "vless-reality")
            put("runtimeFamily", "reality-whitelist-assisted")
            put("activationState", "active")
            put("configMode", "lab")
        }))
        assertEquals("available", classifySystemRestoreAvailability(true, JSObject().apply { put("protocol", "vless-reality") }))
    }

    @Test
    fun bootRestoreAvailabilityAddsBootGate() {
        val request = JSObject().apply { put("protocol", "vless-reality") }

        assertEquals("resume_ineligible", classifyBootRestoreAvailability(false, true, request))
        assertEquals("boot_restore_disabled", classifyBootRestoreAvailability(true, false, request))
        assertEquals("available", classifyBootRestoreAvailability(true, true, request))
    }

    @Test
    fun armedBootRestoreStateSurvivesCompatibleAppStartRequest() {
        val previous =
            JSObject().apply {
                put("serverHost", "example.com")
                put("transport", "xray")
                put("engine", "sing-box")
                put("protocol", "vless-reality")
                put("profileHash", "hash-a")
                put("configMode", "stable")
                put("bootRestoreEnabled", true)
                put(
                    "profileJson",
                    """
                    {
                      "androidRuntime": {
                        "reality": {
                          "autoRestoreOnBoot": true
                        }
                      }
                    }
                    """.trimIndent(),
                )
            }
        val incoming =
            JSObject().apply {
                put("serverHost", "example.com")
                put("transport", "xray")
                put("engine", "sing-box")
                put("protocol", "vless-reality")
                put("profileHash", "hash-a")
                put("configMode", "stable")
                put("bootRestoreEnabled", false)
                put("profileJson", """{"androidRuntime":{"reality":{}}}""")
            }

        val merged = mergeBootRestoreState(previous, incoming)
        val mergedProfile = JSObject(merged.getString("profileJson", "{}") ?: "{}")

        assertTrue(merged.getBoolean("bootRestoreEnabled", false))
        assertTrue(mergedProfile.getJSONObject("androidRuntime").getJSONObject("reality").getBoolean("autoRestoreOnBoot"))
    }

    @Test
    fun bootRestoreStateDoesNotBleedAcrossDifferentProfiles() {
        val previous =
            JSObject().apply {
                put("serverHost", "example.com")
                put("transport", "xray")
                put("engine", "sing-box")
                put("protocol", "vless-reality")
                put("profileHash", "hash-a")
                put("configMode", "stable")
                put("bootRestoreEnabled", true)
            }
        val incoming =
            JSObject().apply {
                put("serverHost", "example.com")
                put("transport", "xray")
                put("engine", "sing-box")
                put("protocol", "vless-reality")
                put("profileHash", "hash-b")
                put("configMode", "stable")
                put("bootRestoreEnabled", false)
            }

        val merged = mergeBootRestoreState(previous, incoming)

        assertFalse(merged.getBoolean("bootRestoreEnabled", true))
    }

    @Test
    fun bootRestoreStateMatchesLegacyRequestWithoutRuntimeFamilyFields() {
        val previous =
            JSObject().apply {
                put("serverHost", "example.com")
                put("transport", "xray")
                put("engine", "sing-box")
                put("protocol", "vless-reality")
                put("profileHash", "hash-a")
                put("configMode", "stable")
                put("bootRestoreEnabled", true)
            }
        val incoming =
            JSObject().apply {
                put("serverHost", "example.com")
                put("transport", "xray")
                put("engine", "sing-box")
                put("protocol", "vless-reality")
                put("runtimeFamily", "direct-reality")
                put("activationState", "active")
                put("profileHash", "hash-a")
                put("configMode", "stable")
                put("bootRestoreEnabled", false)
                put("profileJson", """{"androidRuntime":{"reality":{}}}""")
            }

        val merged = mergeBootRestoreState(previous, incoming)

        assertTrue(merged.getBoolean("bootRestoreEnabled", false))
    }

    @Test
    fun preferredRestoreRequestKeepsArmedBootRestoreAcrossStores() {
        val credential =
            JSObject().apply {
                put("serverHost", "example.com")
                put("protocol", "vless-reality")
                put("bootRestoreEnabled", false)
            }
        val deviceProtected =
            JSObject().apply {
                put("serverHost", "example.com")
                put("protocol", "vless-reality")
                put("bootRestoreEnabled", true)
            }

        val preferred = selectPreferredRestoreRequest(credential, deviceProtected)

        assertTrue(preferred!!.getBoolean("bootRestoreEnabled", false))
    }

    @Test
    fun withBootRestoreEnabledPatchesProfileJson() {
        val request =
            JSObject().apply {
                put("serverHost", "example.com")
                put("transport", "xray")
                put("engine", "sing-box")
                put("protocol", "vless-reality")
                put("bootRestoreEnabled", false)
                put("profileJson", """{"androidRuntime":{"reality":{}}}""")
            }

        val patched = withBootRestoreEnabled(request, true)
        val profile = JSObject(patched.getString("profileJson", "{}") ?: "{}")
        val normalized = VpnRuntimeLibbox.normalizeRuntimeArgs(patched)

        assertTrue(patched.getBoolean("bootRestoreEnabled", false))
        assertTrue(profile.getJSONObject("androidRuntime").getJSONObject("reality").getBoolean("autoRestoreOnBoot"))
        assertTrue(normalized.getBoolean("bootRestoreEnabled", false))
        assertFeature(normalized, "boot-restore")
        assertNotEquals("", normalized.getString("profileHash", ""))
    }

    @Test(expected = IllegalArgumentException::class)
    fun includeAndExcludePackagesCannotBeCombined() {
        VpnRuntimeLibbox.normalizeRuntimeArgs(
            JSObject().apply {
                put("serverHost", "example.com")
                put("transport", "xray")
                put("engine", "sing-box")
                put("protocol", "vless-reality")
                put(
                    "profileJson",
                    """
                    {
                      "androidRuntime": {
                        "reality": {
                          "includePackages": ["com.android.chrome"],
                          "excludePackages": ["com.android.captiveportallogin"]
                        }
                      }
                    }
                    """.trimIndent(),
                )
            },
        )
    }

    @Test(expected = IllegalArgumentException::class)
    fun encryptedDnsRequiresServerNameForCustomIpResolver() {
        VpnRuntimeLibbox.normalizeRuntimeArgs(
            JSObject().apply {
                put("serverHost", "example.com")
                put("transport", "xray")
                put("engine", "sing-box")
                put("protocol", "vless-reality")
                put(
                    "profileJson",
                    """
                    {
                      "androidRuntime": {
                        "reality": {
                          "mode": "experimental",
                          "dnsMode": "dot",
                          "dnsServer": "8.8.8.8"
                        }
                      }
                    }
                    """.trimIndent(),
                )
            },
        )
    }

    @Test(expected = IllegalArgumentException::class)
    fun encryptedDnsRejectsDomainServerWithoutBootstrapResolver() {
        VpnRuntimeLibbox.normalizeRuntimeArgs(
            JSObject().apply {
                put("serverHost", "example.com")
                put("transport", "xray")
                put("engine", "sing-box")
                put("protocol", "vless-reality")
                put(
                    "profileJson",
                    """
                    {
                      "androidRuntime": {
                        "reality": {
                          "mode": "stable",
                          "dnsMode": "dot",
                          "dnsServer": "dns.google",
                          "dnsServerName": "dns.google"
                        }
                      }
                    }
                    """.trimIndent(),
                )
            },
        )
    }

    private fun assertFeature(
        args: JSObject,
        expected: String,
    ) {
        val features = args.optJSONArray("activeFeatures") ?: JSONArray()
        val normalized =
            buildList(features.length()) {
                for (index in 0 until features.length()) {
                    add(features.optString(index))
                }
            }
        assertTrue("Expected feature '$expected' in $normalized", normalized.contains(expected))
    }

    private fun jsonArrayContainsObjectWithString(
        array: JSONArray,
        key: String,
        expected: String,
    ): Boolean {
        for (index in 0 until array.length()) {
            val item = array.optJSONObject(index) ?: continue
            if (item.optString(key) == expected) {
                return true
            }
        }
        return false
    }

    private fun jsonArrayFindObjectWithString(
        array: JSONArray,
        key: String,
        expected: String,
    ): JSONObject? {
        for (index in 0 until array.length()) {
            val item = array.optJSONObject(index) ?: continue
            if (item.optString(key) == expected) {
                return item
            }
        }
        return null
    }

    private fun jsonArrayContainsRule(
        array: JSONArray,
        matchKey: String,
        matchValue: String,
        resultKey: String,
        resultValue: String,
    ): Boolean {
        for (index in 0 until array.length()) {
            val item = array.optJSONObject(index) ?: continue
            if (item.optString(resultKey) != resultValue) {
                continue
            }
            val values = item.optJSONArray(matchKey) ?: continue
            for (valueIndex in 0 until values.length()) {
                if (values.optString(valueIndex) == matchValue) {
                    return true
                }
            }
        }
        return false
    }

    private fun jsonArrayContainsDnsRule(
        array: JSONArray,
        matchKey: String,
        matchValue: String,
        resultKey: String,
        resultValue: String,
    ): Boolean {
        for (index in 0 until array.length()) {
            val item = array.optJSONObject(index) ?: continue
            if (item.optString(resultKey) != resultValue) {
                continue
            }
            val values = item.optJSONArray(matchKey) ?: continue
            for (valueIndex in 0 until values.length()) {
                if (values.optString(valueIndex) == matchValue) {
                    return true
                }
            }
        }
        return false
    }
}
