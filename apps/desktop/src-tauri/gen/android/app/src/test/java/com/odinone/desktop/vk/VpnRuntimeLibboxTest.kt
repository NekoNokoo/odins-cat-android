package com.odinone.desktop.vk

import app.tauri.plugin.JSObject
import org.json.JSONArray
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
    fun requestMatchingIncludesProfileHashAndConfigMode() {
        val snapshot =
            TunnelSnapshot(
                status = "running",
                serverHost = "example.com",
                transport = "xray",
                engine = "sing-box",
                protocol = "vless-reality",
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
    fun startSnapshotInitializesFreshRecoverySessionCounters() {
        val snapshot =
            startSnapshotFromArgs(
                JSObject().apply {
                    put("serverHost", "example.com")
                    put("transport", "xray")
                    put("engine", "sing-box")
                    put("protocol", "vless-reality")
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
    fun runningSnapshotsNormalizePreRunningStartupStages() {
        assertEquals("running", normalizeRunningStartupStage("running", "socks_ready"))
        assertEquals("running", normalizeRunningStartupStage("running", "service_started"))
        assertEquals("running", normalizeRunningStartupStage("running", null))
        assertEquals("waiting_for_relay", normalizeRunningStartupStage("starting", "waiting_for_relay"))
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

        val merged = mergePersistedRealityOverrides(previous, incoming)
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

        val merged = mergePersistedRealityOverrides(previous, incoming)
        val normalized = VpnRuntimeLibbox.normalizeRuntimeArgs(merged)

        assertEquals("udp", normalized.getString("dnsMode", null))
        assertEquals("1.1.1.1", normalized.getString("dnsServer", null))
        assertEquals("cloudflare-dns.com", normalized.getString("dnsServerName", null))
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
    }

    @Test
    fun systemRestoreAvailabilityReportsUsefulSkipReasons() {
        assertEquals("resume_ineligible", classifySystemRestoreAvailability(false, JSObject().apply { put("protocol", "vless-reality") }))
        assertEquals("missing_request", classifySystemRestoreAvailability(true, null))
        assertEquals("protocol_mismatch", classifySystemRestoreAvailability(true, JSObject().apply { put("protocol", "direct-wireguard") }))
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
}
