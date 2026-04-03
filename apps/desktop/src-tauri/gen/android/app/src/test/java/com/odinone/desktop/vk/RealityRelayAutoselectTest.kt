package com.odinone.desktop.vk

import app.tauri.plugin.JSObject
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RealityRelayAutoselectTest {
    @Test
    fun parseRelayCandidateExtractsRealityTcpFields() {
        val candidate =
            parseRelayCandidate(
                "vless://6492901c-7fcc-49e3-b719-c82b3c6f99ef@217.16.17.95:443?type=tcp&security=reality&sni=id.x5.ru&fp=chrome&pbk=XguLRlc-hWqFhf8-KTxtCE434F6e4Hiqoc5cTBpLxnE&sid=111111&flow=xtls-rprx-vision#The%20Netherlands%20%F0%9F%87%B7%F0%9F%87%BA%20CIDR",
            )

        assertNotNull(candidate)
        assertEquals("217.16.17.95", candidate?.host)
        assertEquals(443, candidate?.port)
        assertEquals("id.x5.ru", candidate?.sni)
        assertEquals("tcp", candidate?.transport)
        assertEquals("reality", candidate?.security)
        assertEquals("xtls-rprx-vision", candidate?.flow)
        assertEquals("chrome", candidate?.fingerprint)
        assertEquals("111111", candidate?.shortId)
    }

    @Test
    fun parseRelayCandidateRejectsUnsupportedOrIncompleteEntries() {
        assertNull(
            parseRelayCandidate(
                "vless://abc@relay.example.com:443?type=ws&security=reality&sni=max.ru&pbk=pk&sid=11#bad-ws",
            ),
        )
        assertNull(
            parseRelayCandidate(
                "vless://abc@relay.example.com:443?type=tcp&security=reality&sni=&pbk=pk&sid=11#missing-sni",
            ),
        )
    }

    @Test
    fun chooseBestCandidatePrefersFastRussianEntry() {
        val options =
            RealityRelayAutoselectOptions(
                enabled = true,
                subscriptionUrl = "https://example.com/sub.txt",
                sourceLabel = "test",
                refreshIntervalHours = 1,
                russianLatencyThresholdMs = 300,
                latencyTimeoutMs = 1200,
                candidateLimit = 8,
                maxPerSni = 2,
                preferOwnerRelayStability = false,
            )
        val ranked =
            listOf(
                RealityRelayCandidate(
                    uri = "vless://a@1.1.1.1:443?type=tcp&security=reality&sni=max.ru&pbk=pk&sid=11#RU",
                    host = "1.1.1.1",
                    port = 443,
                    uuid = "a",
                    transport = "tcp",
                    security = "reality",
                    sni = "max.ru",
                    tag = "RU",
                    flow = "xtls-rprx-vision",
                    fingerprint = "chrome",
                    publicKey = "pk",
                    shortId = "11",
                    grpcServiceName = null,
                    grpcAuthority = null,
                    regionBucket = "russia",
                    preScore = 100,
                    tcpLatencyMs = 42,
                    selectionScore = 1458,
                ),
                RealityRelayCandidate(
                    uri = "vless://b@2.2.2.2:443?type=tcp&security=reality&sni=fast.example&pbk=pk&sid=22#DE",
                    host = "2.2.2.2",
                    port = 443,
                    uuid = "b",
                    transport = "tcp",
                    security = "reality",
                    sni = "fast.example",
                    tag = "DE",
                    flow = "xtls-rprx-vision",
                    fingerprint = "chrome",
                    publicKey = "pk",
                    shortId = "22",
                    grpcServiceName = null,
                    grpcAuthority = null,
                    regionBucket = "other",
                    preScore = 120,
                    tcpLatencyMs = 8,
                    selectionScore = 1492,
                ),
            )

        val best = chooseBestCandidate(ranked, options)

        assertEquals("max.ru", best?.sni)
    }

    @Test
    fun chooseBestCandidatePrefersRelayWithProvenOwnerAndGenericProbeHistory() {
        val options =
            RealityRelayAutoselectOptions(
                enabled = true,
                subscriptionUrl = "https://example.com/sub.txt",
                sourceLabel = "test",
                refreshIntervalHours = 1,
                russianLatencyThresholdMs = 300,
                latencyTimeoutMs = 1200,
                candidateLimit = 8,
                maxPerSni = 2,
                preferOwnerRelayStability = false,
            )
        val proven =
            RealityRelayCandidate(
                uri = "vless://a@1.1.1.1:443?type=tcp&security=reality&sni=max.ru&pbk=pk&sid=11#RU",
                host = "1.1.1.1",
                port = 443,
                uuid = "a",
                transport = "tcp",
                security = "reality",
                sni = "max.ru",
                tag = "RU",
                flow = "xtls-rprx-vision",
                fingerprint = "chrome",
                publicKey = "pk",
                shortId = "11",
                grpcServiceName = null,
                grpcAuthority = null,
                regionBucket = "russia",
                preScore = 100,
                tcpLatencyMs = 70,
                selectionScore = 1430,
            )
        val fasterButUnproven =
            RealityRelayCandidate(
                uri = "vless://b@2.2.2.2:443?type=tcp&security=reality&sni=api.vk.com&pbk=pk&sid=22#RU",
                host = "2.2.2.2",
                port = 443,
                uuid = "b",
                transport = "tcp",
                security = "reality",
                sni = "api.vk.com",
                tag = "RU",
                flow = "xtls-rprx-vision",
                fingerprint = "chrome",
                publicKey = "pk",
                shortId = "22",
                grpcServiceName = null,
                grpcAuthority = null,
                regionBucket = "russia",
                preScore = 120,
                tcpLatencyMs = 9,
                selectionScore = 1491,
            )
        val history =
            JSONObject(
                """
                {
                  "entries": {
                    "1.1.1.1|443|max.ru|tcp|reality|xtls-rprx-vision|pk|11": {
                      "probes": {
                        "owner": { "passCount": 1, "failCount": 0 },
                        "googlevideo": { "passCount": 1, "failCount": 0 }
                      }
                    }
                  },
                  "families": {}
                }
                """.trimIndent(),
            )

        val best = chooseBestCandidate(listOf(proven, fasterButUnproven), options, history)

        assertEquals("max.ru", best?.sni)
    }

    @Test
    fun chooseBestCandidateFallsBackToLatencyWhenNoProbeHistoryExists() {
        val options =
            RealityRelayAutoselectOptions(
                enabled = true,
                subscriptionUrl = "https://example.com/sub.txt",
                sourceLabel = "test",
                refreshIntervalHours = 1,
                russianLatencyThresholdMs = 300,
                latencyTimeoutMs = 1200,
                candidateLimit = 8,
                maxPerSni = 2,
                preferOwnerRelayStability = false,
            )
        val slower =
            RealityRelayCandidate(
                uri = "vless://a@1.1.1.1:443?type=tcp&security=reality&sni=max.ru&pbk=pk&sid=11#RU",
                host = "1.1.1.1",
                port = 443,
                uuid = "a",
                transport = "tcp",
                security = "reality",
                sni = "max.ru",
                tag = "RU",
                flow = "xtls-rprx-vision",
                fingerprint = "chrome",
                publicKey = "pk",
                shortId = "11",
                grpcServiceName = null,
                grpcAuthority = null,
                regionBucket = "russia",
                preScore = 150,
                tcpLatencyMs = 55,
                selectionScore = 1445,
            )
        val faster =
            RealityRelayCandidate(
                uri = "vless://b@2.2.2.2:443?type=tcp&security=reality&sni=api.vk.com&pbk=pk&sid=22#RU",
                host = "2.2.2.2",
                port = 443,
                uuid = "b",
                transport = "tcp",
                security = "reality",
                sni = "api.vk.com",
                tag = "RU",
                flow = "xtls-rprx-vision",
                fingerprint = "chrome",
                publicKey = "pk",
                shortId = "22",
                grpcServiceName = null,
                grpcAuthority = null,
                regionBucket = "russia",
                preScore = 120,
                tcpLatencyMs = 12,
                selectionScore = 1488,
            )

        val best = chooseBestCandidate(listOf(slower, faster), options, JSONObject())

        assertEquals("api.vk.com", best?.sni)
    }

    @Test
    fun chooseBestCandidateInDirectModePrefersGenericProbeWinnerOverLowerLatency() {
        val options =
            RealityRelayAutoselectOptions(
                enabled = true,
                subscriptionUrl = "https://example.com/sub.txt",
                sourceLabel = "test",
                refreshIntervalHours = 1,
                russianLatencyThresholdMs = 300,
                latencyTimeoutMs = 1200,
                candidateLimit = 8,
                maxPerSni = 2,
                preferOwnerRelayStability = false,
            )
        val provenGeneric =
            RealityRelayCandidate(
                uri = "vless://a@1.1.1.1:443?type=tcp&security=reality&sni=m.vk.com&pbk=pk&sid=11#RU",
                host = "1.1.1.1",
                port = 443,
                uuid = "a",
                transport = "tcp",
                security = "reality",
                sni = "m.vk.com",
                tag = "RU",
                flow = "xtls-rprx-vision",
                fingerprint = "chrome",
                publicKey = "pk",
                shortId = "11",
                grpcServiceName = null,
                grpcAuthority = null,
                regionBucket = "russia",
                preScore = 110,
                tcpLatencyMs = 72,
                selectionScore = 1410,
            )
        val fasterButUnknown =
            RealityRelayCandidate(
                uri = "vless://b@2.2.2.2:443?type=tcp&security=reality&sni=max.ru&pbk=pk2&sid=22#RU",
                host = "2.2.2.2",
                port = 443,
                uuid = "b",
                transport = "tcp",
                security = "reality",
                sni = "max.ru",
                tag = "RU",
                flow = "xtls-rprx-vision",
                fingerprint = "random",
                publicKey = "pk2",
                shortId = "22",
                grpcServiceName = null,
                grpcAuthority = null,
                regionBucket = "russia",
                preScore = 160,
                tcpLatencyMs = 12,
                selectionScore = 1488,
            )
        val history =
            JSONObject(
                """
                {
                  "entries": {
                    "1.1.1.1|443|m.vk.com|tcp|reality|xtls-rprx-vision|pk|11": {
                      "probes": {
                        "googlevideo": { "passCount": 1, "failCount": 0 }
                      }
                    }
                  },
                  "families": {}
                }
                """.trimIndent(),
            )

        val best = chooseBestCandidate(listOf(provenGeneric, fasterButUnknown), options, history)

        assertEquals("m.vk.com", best?.sni)
    }

    @Test
    fun chooseBestCandidateInDirectModeDemotesRelayWithFreshGenericFailure() {
        val options =
            RealityRelayAutoselectOptions(
                enabled = true,
                subscriptionUrl = "https://example.com/sub.txt",
                sourceLabel = "test",
                refreshIntervalHours = 1,
                russianLatencyThresholdMs = 300,
                latencyTimeoutMs = 1200,
                candidateLimit = 8,
                maxPerSni = 2,
                preferOwnerRelayStability = false,
            )
        val fasterButDirty =
            RealityRelayCandidate(
                uri = "vless://a@1.1.1.1:443?type=tcp&security=reality&sni=max.ru&pbk=pk&sid=11#RU",
                host = "1.1.1.1",
                port = 443,
                uuid = "a",
                transport = "tcp",
                security = "reality",
                sni = "max.ru",
                tag = "RU",
                flow = "xtls-rprx-vision",
                fingerprint = "chrome",
                publicKey = "pk",
                shortId = "11",
                grpcServiceName = null,
                grpcAuthority = null,
                regionBucket = "russia",
                preScore = 175,
                tcpLatencyMs = 9,
                selectionScore = 1499,
            )
        val slowerButClean =
            RealityRelayCandidate(
                uri = "vless://b@2.2.2.2:443?type=tcp&security=reality&sni=api.vk.com&pbk=pk2&sid=22#RU",
                host = "2.2.2.2",
                port = 443,
                uuid = "b",
                transport = "tcp",
                security = "reality",
                sni = "api.vk.com",
                tag = "RU",
                flow = "xtls-rprx-vision",
                fingerprint = "random",
                publicKey = "pk2",
                shortId = "22",
                grpcServiceName = null,
                grpcAuthority = null,
                regionBucket = "russia",
                preScore = 140,
                tcpLatencyMs = 44,
                selectionScore = 1405,
            )
        val history =
            JSONObject(
                """
                {
                  "entries": {
                    "1.1.1.1|443|max.ru|tcp|reality|xtls-rprx-vision|pk|11": {
                      "probes": {
                        "googlevideo": {
                          "passCount": 0,
                          "failCount": 1,
                          "lastOutcome": "failed"
                        }
                      }
                    }
                  },
                  "families": {}
                }
                """.trimIndent(),
            )

        val best = chooseBestCandidate(listOf(fasterButDirty, slowerButClean), options, history)

        assertEquals("api.vk.com", best?.sni)
    }

    @Test
    fun chooseBestCandidateInOwnerEgressModePrefersMoreStableRelayOverBareLatency() {
        val options =
            RealityRelayAutoselectOptions(
                enabled = true,
                subscriptionUrl = "https://example.com/sub.txt",
                sourceLabel = "test",
                refreshIntervalHours = 1,
                russianLatencyThresholdMs = 300,
                latencyTimeoutMs = 1200,
                candidateLimit = 8,
                maxPerSni = 2,
                preferOwnerRelayStability = true,
            )
        val stable =
            RealityRelayCandidate(
                uri = "vless://a@1.1.1.1:443?type=tcp&security=reality&sni=5post-gate.x5.ru&pbk=pk-1&sid=11#RU",
                host = "1.1.1.1",
                port = 443,
                uuid = "a",
                transport = "tcp",
                security = "reality",
                sni = "5post-gate.x5.ru",
                tag = "RU",
                flow = "xtls-rprx-vision",
                fingerprint = "chrome",
                publicKey = "pk-1",
                shortId = "11",
                grpcServiceName = null,
                grpcAuthority = null,
                regionBucket = "russia",
                preScore = 180,
                tcpLatencyMs = 41,
                selectionScore = 1639,
            )
        val merelyFaster =
            RealityRelayCandidate(
                uri = "vless://b@2.2.2.2:7443?type=tcp&security=reality&sni=chat.deepseek.com&pbk=pk-2&sid=22#RU",
                host = "2.2.2.2",
                port = 7443,
                uuid = "b",
                transport = "tcp",
                security = "reality",
                sni = "chat.deepseek.com",
                tag = "RU",
                flow = "xtls-rprx-vision",
                fingerprint = "chrome",
                publicKey = "pk-2",
                shortId = "22",
                grpcServiceName = null,
                grpcAuthority = null,
                regionBucket = "russia",
                preScore = 162,
                tcpLatencyMs = 39,
                selectionScore = 1623,
            )

        val best = chooseBestCandidate(listOf(stable, merelyFaster), options, JSONObject())

        assertEquals("5post-gate.x5.ru", best?.sni)
    }

    @Test
    fun chooseBestCandidateInOwnerEgressModePrefersKnownSecondHopSeedOverFasterGeneralRelay() {
        val options =
            RealityRelayAutoselectOptions(
                enabled = true,
                subscriptionUrl = "https://example.com/sub.txt",
                sourceLabel = "test",
                refreshIntervalHours = 1,
                russianLatencyThresholdMs = 300,
                latencyTimeoutMs = 1200,
                candidateLimit = 8,
                maxPerSni = 2,
                preferOwnerRelayStability = true,
            )
        val preferredSeed =
            RealityRelayCandidate(
                uri = "vless://a@217.16.21.235:443?type=tcp&security=reality&sni=5post-gate.x5.ru&pbk=pk-1&sid=11#RU",
                host = "217.16.21.235",
                port = 443,
                uuid = "a",
                transport = "tcp",
                security = "reality",
                sni = "5post-gate.x5.ru",
                tag = "RU",
                flow = "xtls-rprx-vision",
                fingerprint = "chrome",
                publicKey = "pk-1",
                shortId = "11",
                grpcServiceName = null,
                grpcAuthority = null,
                regionBucket = "russia",
                preScore = 175,
                tcpLatencyMs = 45,
                selectionScore = 1630,
            )
        val fasterGeneralRelay =
            RealityRelayCandidate(
                uri = "vless://b@89.208.87.108:443?type=tcp&security=reality&sni=max.ru&pbk=pk-2&sid=22#RU",
                host = "89.208.87.108",
                port = 443,
                uuid = "b",
                transport = "tcp",
                security = "reality",
                sni = "max.ru",
                tag = "RU",
                flow = "xtls-rprx-vision",
                fingerprint = "random",
                publicKey = "pk-2",
                shortId = "22",
                grpcServiceName = null,
                grpcAuthority = null,
                regionBucket = "russia",
                preScore = 181,
                tcpLatencyMs = 33,
                selectionScore = 1648,
            )

        val best = chooseBestCandidate(listOf(preferredSeed, fasterGeneralRelay), options, JSONObject())

        assertEquals("5post-gate.x5.ru", best?.sni)
    }

    @Test
    fun chooseBestCandidateInOwnerEgressModePrefersStickyExactRelayOverFeedDrift() {
        val options =
            RealityRelayAutoselectOptions(
                enabled = true,
                subscriptionUrl = "https://example.com/sub.txt",
                sourceLabel = "test",
                refreshIntervalHours = 1,
                russianLatencyThresholdMs = 300,
                latencyTimeoutMs = 1200,
                candidateLimit = 8,
                maxPerSni = 2,
                preferOwnerRelayStability = true,
            )
        val stickyApiRelay =
            RealityRelayCandidate(
                uri = "vless://56022eef-4ade-4240-b0cc-eb006797e7ac@94.126.207.245:443?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&fp=random&sni=api.vk.com&pbk=V32osv0u9T3QItvyk4UgK-mjJuXkXLn4u_3pbk8eNgs&sid=9339#RU",
                host = "94.126.207.245",
                port = 443,
                uuid = "56022eef-4ade-4240-b0cc-eb006797e7ac",
                transport = "tcp",
                security = "reality",
                sni = "api.vk.com",
                tag = "RU",
                flow = "xtls-rprx-vision",
                fingerprint = "random",
                publicKey = "V32osv0u9T3QItvyk4UgK-mjJuXkXLn4u_3pbk8eNgs",
                shortId = "9339",
                grpcServiceName = null,
                grpcAuthority = null,
                regionBucket = "russia",
                preScore = 170,
                tcpLatencyMs = 38,
                selectionScore = 1632,
            )
        val fasterFeedWinner =
            RealityRelayCandidate(
                uri = "vless://71e93f23-9bf6-4058-8784-05776a926dba@89.208.87.108:443?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&fp=random&sni=max.ru&pbk=WWA4FL9fWO0sy41E-fciX6ZTKUL4U2MxhpXJs9jPQ2I&sid=b2a6e3d42f05c3d1#RU",
                host = "89.208.87.108",
                port = 443,
                uuid = "71e93f23-9bf6-4058-8784-05776a926dba",
                transport = "tcp",
                security = "reality",
                sni = "max.ru",
                tag = "RU",
                flow = "xtls-rprx-vision",
                fingerprint = "random",
                publicKey = "WWA4FL9fWO0sy41E-fciX6ZTKUL4U2MxhpXJs9jPQ2I",
                shortId = "b2a6e3d42f05c3d1",
                grpcServiceName = null,
                grpcAuthority = null,
                regionBucket = "russia",
                preScore = 181,
                tcpLatencyMs = 31,
                selectionScore = 1649,
            )

        val best = chooseBestCandidate(listOf(fasterFeedWinner, stickyApiRelay), options, JSONObject())

        assertEquals("api.vk.com", best?.sni)
        assertEquals("94.126.207.245", best?.host)
    }

    @Test
    fun chooseBestCandidateInOwnerEgressModePrefersCleanExactHistoryOverDirtySeed() {
        val options =
            RealityRelayAutoselectOptions(
                enabled = true,
                subscriptionUrl = "https://example.com/sub.txt",
                sourceLabel = "test",
                refreshIntervalHours = 1,
                russianLatencyThresholdMs = 300,
                latencyTimeoutMs = 1200,
                candidateLimit = 8,
                maxPerSni = 2,
                preferOwnerRelayStability = true,
            )
        val dirtySeed =
            RealityRelayCandidate(
                uri = "vless://a@217.16.21.235:443?type=tcp&security=reality&sni=5post-gate.x5.ru&pbk=pk-1&sid=11#RU",
                host = "217.16.21.235",
                port = 443,
                uuid = "a",
                transport = "tcp",
                security = "reality",
                sni = "5post-gate.x5.ru",
                tag = "RU",
                flow = "xtls-rprx-vision",
                fingerprint = "random",
                publicKey = "pk-1",
                shortId = "11",
                grpcServiceName = null,
                grpcAuthority = null,
                regionBucket = "russia",
                preScore = 185,
                tcpLatencyMs = 36,
                selectionScore = 1649,
            )
        val cleanGrpc =
            RealityRelayCandidate(
                uri = "vless://b@217.16.26.229:7443?type=grpc&security=reality&sni=ads.x5.ru&pbk=pk-2&sid=22#RU",
                host = "217.16.26.229",
                port = 7443,
                uuid = "b",
                transport = "grpc",
                security = "reality",
                sni = "ads.x5.ru",
                tag = "RU",
                flow = "xtls-rprx-vision",
                fingerprint = "qq",
                publicKey = "pk-2",
                shortId = "22",
                grpcServiceName = "UpdateService",
                grpcAuthority = null,
                regionBucket = "russia",
                preScore = 170,
                tcpLatencyMs = 7,
                selectionScore = 1663,
            )
        val history =
            JSONObject(
                """
                {
                  "entries": {
                    "217.16.21.235|443|5post-gate.x5.ru|tcp|reality|xtls-rprx-vision|pk-1|11": {
                      "probes": {
                        "owner": { "passCount": 2, "failCount": 1, "lastOutcome": "failed" },
                        "googlevideo": { "passCount": 2, "failCount": 0, "lastOutcome": "passed" }
                      }
                    },
                    "217.16.26.229|7443|ads.x5.ru|grpc|reality|xtls-rprx-vision|pk-2|22": {
                      "probes": {
                        "owner": { "passCount": 1, "failCount": 0, "lastOutcome": "passed" },
                        "googlevideo": { "passCount": 1, "failCount": 0, "lastOutcome": "passed" }
                      }
                    }
                  },
                  "families": {}
                }
                """.trimIndent(),
            )

        val best = chooseBestCandidate(listOf(dirtySeed, cleanGrpc), options, history)

        assertEquals("ads.x5.ru", best?.sni)
    }

    @Test
    fun chooseBestCandidateInOwnerEgressModePrefersFreshProvenFeedCandidateBeforeStickyFallback() {
        val options =
            RealityRelayAutoselectOptions(
                enabled = true,
                subscriptionUrl = "https://example.com/sub.txt",
                sourceLabel = "test",
                refreshIntervalHours = 1,
                russianLatencyThresholdMs = 300,
                latencyTimeoutMs = 1200,
                candidateLimit = 8,
                maxPerSni = 2,
                preferOwnerRelayStability = true,
            )
        val provenApiRelay =
            RealityRelayCandidate(
                uri = "vless://a@94.126.207.245:443?type=tcp&security=reality&sni=api.vk.com&pbk=pk-1&sid=11#RU",
                host = "94.126.207.245",
                port = 443,
                uuid = "a",
                transport = "tcp",
                security = "reality",
                sni = "api.vk.com",
                tag = "RU",
                flow = "xtls-rprx-vision",
                fingerprint = "qq",
                publicKey = "pk-1",
                shortId = "11",
                grpcServiceName = null,
                grpcAuthority = null,
                regionBucket = "russia",
                preScore = 160,
                tcpLatencyMs = 58,
                selectionScore = 1600,
            )
        val cleanAdsRelay =
            RealityRelayCandidate(
                uri = "vless://b@37.9.4.241:443?type=tcp&security=reality&sni=ads.x5.ru&pbk=pk-2&sid=22#RU",
                host = "37.9.4.241",
                port = 443,
                uuid = "b",
                transport = "tcp",
                security = "reality",
                sni = "ads.x5.ru",
                tag = "RU",
                flow = "xtls-rprx-vision",
                fingerprint = "random",
                publicKey = "pk-2",
                shortId = "22",
                grpcServiceName = null,
                grpcAuthority = null,
                regionBucket = "russia",
                preScore = 190,
                tcpLatencyMs = 12,
                selectionScore = 1688,
            )
        val history =
            JSONObject(
                """
                {
                  "entries": {
                    "37.9.4.241|443|ads.x5.ru|tcp|reality|xtls-rprx-vision|pk-2|22": {
                      "probes": {
                        "owner": { "passCount": 1, "failCount": 0, "lastOutcome": "passed" },
                        "googlevideo": { "passCount": 1, "failCount": 0, "lastOutcome": "passed" }
                      }
                    }
                  },
                  "families": {}
                }
                """.trimIndent(),
            )

        val best = chooseBestCandidate(listOf(cleanAdsRelay, provenApiRelay), options, history)

        assertEquals("ads.x5.ru", best?.sni)
    }

    @Test
    fun preselectCandidatesInOwnerEgressModeKeepsSeedFamilyInsideShortlist() {
        val options =
            RealityRelayAutoselectOptions(
                enabled = true,
                subscriptionUrl = "https://example.com/sub.txt",
                sourceLabel = "test",
                refreshIntervalHours = 1,
                russianLatencyThresholdMs = 300,
                latencyTimeoutMs = 1200,
                candidateLimit = 2,
                maxPerSni = 2,
                preferOwnerRelayStability = true,
            )
        val ranked =
            listOf(
                RealityRelayCandidate(
                    uri = "vless://a@94.139.251.109:7443?type=tcp&security=reality&sni=chat.deepseek.com&pbk=pk-1&sid=11#RU",
                    host = "94.139.251.109",
                    port = 7443,
                    uuid = "a",
                    transport = "tcp",
                    security = "reality",
                    sni = "chat.deepseek.com",
                    tag = "RU",
                    flow = "xtls-rprx-vision",
                    fingerprint = "chrome",
                    publicKey = "pk-1",
                    shortId = "11",
                    grpcServiceName = null,
                    grpcAuthority = null,
                    regionBucket = "russia",
                    preScore = 187,
                ),
                RealityRelayCandidate(
                    uri = "vless://b@217.16.21.235:443?type=tcp&security=reality&sni=5post-gate.x5.ru&pbk=pk-2&sid=22#RU",
                    host = "217.16.21.235",
                    port = 443,
                    uuid = "b",
                    transport = "tcp",
                    security = "reality",
                    sni = "5post-gate.x5.ru",
                    tag = "RU",
                    flow = "xtls-rprx-vision",
                    fingerprint = "random",
                    publicKey = "pk-2",
                    shortId = "22",
                    grpcServiceName = null,
                    grpcAuthority = null,
                    regionBucket = "russia",
                    preScore = 140,
                ),
                RealityRelayCandidate(
                    uri = "vless://c@217.16.21.235:443?type=tcp&security=reality&sni=5post-gate.x5.ru&pbk=pk-3&sid=33#RU",
                    host = "217.16.21.235",
                    port = 443,
                    uuid = "c",
                    transport = "tcp",
                    security = "reality",
                    sni = "5post-gate.x5.ru",
                    tag = "RU",
                    flow = "xtls-rprx-vision",
                    fingerprint = "chrome",
                    publicKey = "pk-3",
                    shortId = "33",
                    grpcServiceName = null,
                    grpcAuthority = null,
                    regionBucket = "russia",
                    preScore = 139,
                ),
            )

        val selected = preselectCandidates(ranked, options)

        assertEquals(2, selected.size)
        assertEquals("5post-gate.x5.ru", selected[0].sni)
        assertEquals("5post-gate.x5.ru", selected[1].sni)
    }

    @Test
    fun preselectCandidatesInOwnerEgressModePrefersCleanerHistoryBeforeSeedBias() {
        val options =
            RealityRelayAutoselectOptions(
                enabled = true,
                subscriptionUrl = "https://example.com/sub.txt",
                sourceLabel = "test",
                refreshIntervalHours = 1,
                russianLatencyThresholdMs = 300,
                latencyTimeoutMs = 1200,
                candidateLimit = 2,
                maxPerSni = 2,
                preferOwnerRelayStability = true,
            )
        val ranked =
            listOf(
                RealityRelayCandidate(
                    uri = "vless://a@94.139.251.109:7443?type=tcp&security=reality&sni=chat.deepseek.com&pbk=pk-1&sid=11#RU",
                    host = "94.139.251.109",
                    port = 7443,
                    uuid = "a",
                    transport = "tcp",
                    security = "reality",
                    sni = "chat.deepseek.com",
                    tag = "RU",
                    flow = "xtls-rprx-vision",
                    fingerprint = "chrome",
                    publicKey = "pk-1",
                    shortId = "11",
                    grpcServiceName = null,
                    grpcAuthority = null,
                    regionBucket = "russia",
                    preScore = 190,
                ),
                RealityRelayCandidate(
                    uri = "vless://b@217.16.21.235:443?type=tcp&security=reality&sni=5post-gate.x5.ru&pbk=pk-2&sid=22#RU",
                    host = "217.16.21.235",
                    port = 443,
                    uuid = "b",
                    transport = "tcp",
                    security = "reality",
                    sni = "5post-gate.x5.ru",
                    tag = "RU",
                    flow = "xtls-rprx-vision",
                    fingerprint = "random",
                    publicKey = "pk-2",
                    shortId = "22",
                    grpcServiceName = null,
                    grpcAuthority = null,
                    regionBucket = "russia",
                    preScore = 180,
                ),
                RealityRelayCandidate(
                    uri = "vless://c@217.16.26.229:7443?type=grpc&security=reality&sni=ads.x5.ru&pbk=pk-3&sid=33#RU",
                    host = "217.16.26.229",
                    port = 7443,
                    uuid = "c",
                    transport = "grpc",
                    security = "reality",
                    sni = "ads.x5.ru",
                    tag = "RU",
                    flow = "xtls-rprx-vision",
                    fingerprint = "qq",
                    publicKey = "pk-3",
                    shortId = "33",
                    grpcServiceName = "UpdateService",
                    grpcAuthority = null,
                    regionBucket = "russia",
                    preScore = 150,
                ),
            )
        val history =
            JSONObject(
                """
                {
                  "entries": {
                    "217.16.21.235|443|5post-gate.x5.ru|tcp|reality|xtls-rprx-vision|pk-2|22": {
                      "probes": {
                        "owner": { "passCount": 2, "failCount": 1, "lastOutcome": "failed" },
                        "googlevideo": { "passCount": 2, "failCount": 0, "lastOutcome": "passed" }
                      }
                    },
                    "217.16.26.229|7443|ads.x5.ru|grpc|reality|xtls-rprx-vision|pk-3|33": {
                      "probes": {
                        "owner": { "passCount": 1, "failCount": 0, "lastOutcome": "passed" },
                        "googlevideo": { "passCount": 1, "failCount": 0, "lastOutcome": "passed" }
                      }
                    }
                  },
                  "families": {}
                }
                """.trimIndent(),
            )

        val selected = preselectCandidates(ranked, options, history)

        assertEquals(2, selected.size)
        assertEquals("ads.x5.ru", selected[0].sni)
        assertTrue(selected.any { it.sni == "ads.x5.ru" })
    }

    @Test
    fun preselectCandidatesInOwnerEgressModePrefersFreshProvenFeedCandidateBeforeStickyFallback() {
        val options =
            RealityRelayAutoselectOptions(
                enabled = true,
                subscriptionUrl = "https://example.com/sub.txt",
                sourceLabel = "test",
                refreshIntervalHours = 1,
                russianLatencyThresholdMs = 300,
                latencyTimeoutMs = 1200,
                candidateLimit = 2,
                maxPerSni = 2,
                preferOwnerRelayStability = true,
            )
        val ranked =
            listOf(
                RealityRelayCandidate(
                    uri = "vless://a@37.9.4.241:443?type=tcp&security=reality&sni=ads.x5.ru&pbk=pk-1&sid=11#RU",
                    host = "37.9.4.241",
                    port = 443,
                    uuid = "a",
                    transport = "tcp",
                    security = "reality",
                    sni = "ads.x5.ru",
                    tag = "RU",
                    flow = "xtls-rprx-vision",
                    fingerprint = "random",
                    publicKey = "pk-1",
                    shortId = "11",
                    grpcServiceName = null,
                    grpcAuthority = null,
                    regionBucket = "russia",
                    preScore = 195,
                ),
                RealityRelayCandidate(
                    uri = "vless://b@94.126.207.245:443?type=tcp&security=reality&sni=api.vk.com&pbk=pk-2&sid=22#RU",
                    host = "94.126.207.245",
                    port = 443,
                    uuid = "b",
                    transport = "tcp",
                    security = "reality",
                    sni = "api.vk.com",
                    tag = "RU",
                    flow = "xtls-rprx-vision",
                    fingerprint = "qq",
                    publicKey = "pk-2",
                    shortId = "22",
                    grpcServiceName = null,
                    grpcAuthority = null,
                    regionBucket = "russia",
                    preScore = 165,
                ),
            )
        val history =
            JSONObject(
                """
                {
                  "entries": {
                    "37.9.4.241|443|ads.x5.ru|tcp|reality|xtls-rprx-vision|pk-1|11": {
                      "probes": {
                        "owner": { "passCount": 1, "failCount": 0, "lastOutcome": "passed" },
                        "googlevideo": { "passCount": 1, "failCount": 0, "lastOutcome": "passed" }
                      }
                    }
                  },
                  "families": {}
                }
                """.trimIndent(),
            )

        val selected = preselectCandidates(ranked, options, history)

        assertEquals(2, selected.size)
        assertEquals("ads.x5.ru", selected[0].sni)
        assertEquals("api.vk.com", selected[1].sni)
    }

    @Test
    fun shouldRefreshOnStartRefreshesOwnerEgressModeOnlyOnBackgroundRefreshPath() {
        val options =
            RealityRelayAutoselectOptions(
                enabled = true,
                subscriptionUrl = "https://example.com/sub.txt",
                sourceLabel = "test",
                refreshIntervalHours = 1,
                russianLatencyThresholdMs = 300,
                latencyTimeoutMs = 1200,
                candidateLimit = 8,
                maxPerSni = 2,
                preferOwnerRelayStability = true,
            )
        val state =
            RealityRelayAutoselectState(
                enabled = true,
                status = "ready",
                lastRefreshAt = "2026-04-03T12:00:00Z",
                bestCandidate = null,
            )

        assertTrue(!RealityRelayAutoselect.shouldRefreshOnStart(state, options, refreshIfStale = false))
        assertTrue(RealityRelayAutoselect.shouldRefreshOnStart(state, options, refreshIfStale = true))
    }

    @Test
    fun shouldRefreshOnStartKeepsNormalModeStaleCheck() {
        val options =
            RealityRelayAutoselectOptions(
                enabled = true,
                subscriptionUrl = "https://example.com/sub.txt",
                sourceLabel = "test",
                refreshIntervalHours = 1,
                russianLatencyThresholdMs = 300,
                latencyTimeoutMs = 1200,
                candidateLimit = 8,
                maxPerSni = 2,
                preferOwnerRelayStability = false,
            )
        val state =
            RealityRelayAutoselectState(
                enabled = true,
                status = "ready",
                lastRefreshAt = "3026-04-03T12:00:00Z",
                bestCandidate =
                    RealityRelayCandidate(
                        uri = "vless://a@1.1.1.1:443?type=tcp&security=reality&sni=max.ru&pbk=pk&sid=11#RU",
                        host = "1.1.1.1",
                        port = 443,
                        uuid = "a",
                        transport = "tcp",
                        security = "reality",
                        sni = "max.ru",
                        tag = "RU",
                        flow = "xtls-rprx-vision",
                        fingerprint = "chrome",
                        publicKey = "pk",
                        shortId = "11",
                        grpcServiceName = null,
                        grpcAuthority = null,
                        regionBucket = "russia",
                        preScore = 100,
                    ),
            )

        assertTrue(!RealityRelayAutoselect.shouldRefreshOnStart(state, options, refreshIfStale = false))
        assertTrue(!RealityRelayAutoselect.shouldRefreshOnStart(state, options, refreshIfStale = true))
    }

    @Test
    fun relayCandidateFromRequestPreservesExactGrpcRealityShape() {
        val request =
            JSObject(
                """
                {
                  "runtimeFamily": "reality-vps-lab",
                  "selectedSniHint": "ads.x5.ru",
                  "whitelistHintTag": "auto-ads-x5-ru-217-16-26-229-7443-grpc",
                  "vpsRealityTransport": "grpc",
                  "vpsRealityConnectHost": "217.16.26.229",
                  "vpsRealityConnectPort": 7443,
                  "profileJson": "{\"stagedFallbacks\":{\"vlessReality\":{\"port\":7443,\"publicKey\":\"pk\",\"serverName\":\"ads.x5.ru\",\"shortId\":\"sid\",\"uuid\":\"uuid-1\",\"flow\":\"xtls-rprx-vision\"}},\"androidRuntime\":{\"realityVpsLab\":{\"enabled\":true,\"mode\":\"lab\",\"serverName\":\"ads.x5.ru\",\"port\":7443,\"transport\":\"grpc\",\"fingerprint\":\"firefox\",\"tag\":\"auto-ads-x5-ru-217-16-26-229-7443-grpc\",\"flow\":\"xtls-rprx-vision\",\"connectHost\":\"217.16.26.229\",\"connectPort\":7443}}}"
                }
                """.trimIndent(),
            )

        val candidate = relayCandidateFromRequest(request)

        assertNotNull(candidate)
        assertEquals("217.16.26.229", candidate?.host)
        assertEquals(7443, candidate?.port)
        assertEquals("ads.x5.ru", candidate?.sni)
        assertEquals("grpc", candidate?.transport)
        assertEquals("pk", candidate?.publicKey)
        assertEquals("sid", candidate?.shortId)
        assertEquals(
            "217.16.26.229|7443|ads.x5.ru|grpc|reality|xtls-rprx-vision|pk|sid",
            candidate?.exactKey(),
        )
    }

    @Test
    fun scoreCandidateUsesRollingHistoryAndRussianBonus() {
        val history =
            JSONObject(
                """
                {
                  "entries": {
                    "1.1.1.1|443|max.ru|tcp|reality|xtls-rprx-vision|pk|11": {
                      "passCount": 2,
                      "failCount": 0
                    }
                  },
                  "families": {
                    "max.ru": {
                      "passCount": 1,
                      "failCount": 0
                    }
                  }
                }
                """.trimIndent(),
            )
        val candidate =
            RealityRelayCandidate(
                uri = "vless://a@1.1.1.1:443?type=tcp&security=reality&sni=max.ru&pbk=pk&sid=11#RU",
                host = "1.1.1.1",
                port = 443,
                uuid = "a",
                transport = "tcp",
                security = "reality",
                sni = "max.ru",
                tag = "RU",
                flow = "xtls-rprx-vision",
                fingerprint = "chrome",
                publicKey = "pk",
                shortId = "11",
                grpcServiceName = null,
                grpcAuthority = null,
                regionBucket = "russia",
                preScore = 0,
            )

        val scored = scoreCandidate(candidate, history, sniCount = 3)

        assertTrue(scored.preScore >= 170)
    }

    @Test
    fun scoreCandidateStronglyPrefersOwnerAndGooglevideoProbeHistory() {
        val history =
            JSONObject(
                """
                {
                  "entries": {
                    "217.16.21.235|443|5post-gate.x5.ru|tcp|reality|xtls-rprx-vision|OCRYYq4e92sQ-wWFRX6WX9pdvuFBWOqybLhpSiv3nFA|111111": {
                      "passCount": 1,
                      "failCount": 0,
                      "probes": {
                        "owner": { "passCount": 1, "failCount": 0 },
                        "googlevideo": { "passCount": 1, "failCount": 0 }
                      }
                    }
                  },
                  "families": {
                    "5post-gate.x5.ru": {
                      "passCount": 1,
                      "failCount": 0,
                      "probes": {
                        "owner": { "passCount": 1, "failCount": 0 },
                        "googlevideo": { "passCount": 1, "failCount": 0 }
                      }
                    }
                  }
                }
                """.trimIndent(),
            )
        val candidate =
            RealityRelayCandidate(
                uri = "vless://48e31d59-0628-000a-b16d-331f1333b3f8@217.16.21.235:443?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&fp=random&sni=5post-gate.x5.ru&pbk=OCRYYq4e92sQ-wWFRX6WX9pdvuFBWOqybLhpSiv3nFA&sid=111111#RU",
                host = "217.16.21.235",
                port = 443,
                uuid = "48e31d59-0628-000a-b16d-331f1333b3f8",
                transport = "tcp",
                security = "reality",
                sni = "5post-gate.x5.ru",
                tag = "RU",
                flow = "xtls-rprx-vision",
                fingerprint = "random",
                publicKey = "OCRYYq4e92sQ-wWFRX6WX9pdvuFBWOqybLhpSiv3nFA",
                shortId = "111111",
                grpcServiceName = null,
                grpcAuthority = null,
                regionBucket = "russia",
                preScore = 0,
            )

        val scored = scoreCandidate(candidate, history, sniCount = 2)

        assertTrue(scored.preScore >= 300)
    }
}
