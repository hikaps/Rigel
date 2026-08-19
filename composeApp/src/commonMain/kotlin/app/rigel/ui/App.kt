package app.rigel.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import app.rigel.cast.CastTarget
import app.rigel.devices.DevicesRepository
import app.rigel.gateway.PlaybackRoute
import app.rigel.player.AirPlayRoutePickerButton
import app.rigel.player.PlayerController
import app.rigel.player.PlayerPhase
import app.rigel.player.PlatformPlayerView
import app.rigel.player.RigelIntake
import app.rigel.settings.RouteOverride
import app.rigel.settings.SettingsStore
import app.rigel.settings.TranscodeCap
import app.rigel.source.jellyfin.JellyfinApi
import app.rigel.source.jellyfin.JellyfinClient
import app.rigel.source.jellyfin.JellyfinItem
import app.rigel.source.jellyfin.JellyfinSession
import com.russhwolf.settings.Settings
import io.ktor.client.HttpClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

enum class Screen { HOME, PLAYER, DEVICES, SETTINGS, SOURCES }

/** Top-level UI state holder; bridges intake (Swift onOpenURL) into Compose. */
object AppState {
    val screen = mutableStateOf(Screen.HOME)

    fun onIntake(url: String): Boolean {
        val ok = RigelIntake.handle(url)
        if (ok) screen.value = Screen.PLAYER
        return ok
    }
}

private val appClient = HttpClient()
private val appSettings = SettingsStore(Settings())
private val appController = PlayerController(appSettings)
private val appDevices = DevicesRepository(appClient, appSettings)

@Composable
fun App() {
    RigelIntake.attach(appController)
    MaterialTheme {
        when (AppState.screen.value) {
            Screen.HOME -> HomeScreen()
            Screen.PLAYER -> PlayerScreen()
            Screen.DEVICES -> DevicesScreen()
            Screen.SETTINGS -> SettingsScreen()
            Screen.SOURCES -> SourcesScreen()
        }
    }
}

@Composable
private fun HomeScreen() {
    var urlText by remember { mutableStateOf("") }
    var errorText by remember { mutableStateOf<String?>(null) }
    Column(
        modifier = Modifier.fillMaxSize().padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text("Rigel", style = MaterialTheme.typography.headlineMedium)
        Text("Open-source iOS player — AirPlay, DLNA, Roku.", style = MaterialTheme.typography.bodyMedium)
        OutlinedTextField(
            value = urlText,
            onValueChange = { urlText = it },
            label = { Text("Stream URL or rigel:// link") },
            modifier = Modifier.fillMaxWidth(),
        )
        if (errorText != null) Text(errorText!!, color = MaterialTheme.colorScheme.error)
        Button(
            onClick = {
                val raw = urlText.trim()
                if (raw.isEmpty()) {
                    errorText = "Paste a URL first"
                } else if (!AppState.onIntake(raw)) {
                    errorText = "Unrecognized URL"
                } else {
                    errorText = null
                }
            },
            modifier = Modifier.fillMaxWidth(),
        ) { Text("Play") }
        Row {
            TextButton(onClick = { AppState.screen.value = Screen.DEVICES }) { Text("Devices") }
            TextButton(onClick = { AppState.screen.value = Screen.SOURCES }) { Text("Sources") }
            TextButton(onClick = { AppState.screen.value = Screen.SETTINGS }) { Text("Settings") }
        }
    }
}

@Composable
private fun PlayerScreen() {
    val state by appController.uiState.collectAsState()
    Box(Modifier.fillMaxSize()) {
        when (state.phase) {
            PlayerPhase.IDLE -> Text("Nothing loaded", modifier = Modifier.align(Alignment.Center))
            PlayerPhase.PROBING, PlayerPhase.PREPARING_PROXY -> Column(
                modifier = Modifier.align(Alignment.Center),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                CircularProgressIndicator()
                Spacer(Modifier.height(12.dp))
                Text(
                    if (state.phase == PlayerPhase.PROBING) "Probing stream…" else "Preparing local conversion…",
                )
            }
            PlayerPhase.PLAYING -> {
                val url = state.proxyUrl ?: state.sourceUrl ?: return@Box
                PlatformPlayerView(
                    sourceUrl = url,
                    title = state.filename ?: state.sourceUrl?.substringAfterLast('/'),
                    sender = state.sender,
                    onReady = { appController.markPlaying() },
                    onError = { appController.reportError(it) },
                    onBack = {
                        appController.stopPlayback()
                        AppState.screen.value = Screen.HOME
                    },
                    modifier = Modifier.fillMaxSize(),
                )
            }
            PlayerPhase.ERROR -> Column(
                modifier = Modifier.align(Alignment.Center).padding(24.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text("Playback error", style = MaterialTheme.typography.titleMedium)
                Spacer(Modifier.height(8.dp))
                Text(state.error ?: "Unknown error", style = MaterialTheme.typography.bodyMedium)
                Spacer(Modifier.height(16.dp))
                Row {
                    Button(onClick = { appController.retryWithProxy() }) { Text("Open via proxy") }
                    Spacer(Modifier.width(8.dp))
                    TextButton(onClick = { AppState.screen.value = Screen.HOME }) { Text("Home") }
                }
            }
        }
    }
}

/** Jellyfin source: connect, browse library, play locally or cast to a client session. */
@Composable
private fun SourcesScreen() {
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    val jfClient = remember { JellyfinClient(appClient) }
    var server by remember { mutableStateOf(appSettings.jellyfinServer()) }
    var username by remember { mutableStateOf(appSettings.jellyfinUsername()) }
    var password by remember { mutableStateOf("") }
    var items by remember { mutableStateOf<List<JellyfinItem>>(emptyList()) }
    var sessions by remember { mutableStateOf<List<JellyfinSession>>(emptyList()) }
    var parentId by remember { mutableStateOf<String?>(null) }
    var notice by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }

    val token = appSettings.jellyfinToken()
    val userId = appSettings.jellyfinUserId()

    Column(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Sources", style = MaterialTheme.typography.headlineSmall, modifier = Modifier.weight(1f))
            TextButton(onClick = { AppState.screen.value = Screen.HOME }) { Text("Back") }
        }

        if (token.isEmpty()) {
            OutlinedTextField(server, { server = it }, label = { Text("Jellyfin server URL") }, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(username, { username = it }, label = { Text("Username") }, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(password, { password = it }, label = { Text("Password") }, modifier = Modifier.fillMaxWidth())
            Button(
                onClick = {
                    scope.launch {
                        busy = true
                        val auth = jfClient.authenticate(server, username, password, "rigel-ios")
                        busy = false
                        if (auth != null) {
                            appSettings.setJellyfinServer(server)
                            appSettings.setJellyfinUsername(username)
                            appSettings.setJellyfinToken(auth.token)
                            appSettings.setJellyfinUserId(auth.userId)
                            notice = "Connected"
                        } else {
                            notice = "Authentication failed"
                        }
                    }
                },
                enabled = !busy,
            ) { Text(if (busy) "Connecting…" else "Connect") }
        } else {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Jellyfin: ${appSettings.jellyfinServer()}", style = MaterialTheme.typography.bodySmall, modifier = Modifier.weight(1f))
                TextButton(onClick = {
                    appSettings.setJellyfinToken("")
                    items = emptyList()
                    sessions = emptyList()
                }) { Text("Disconnect") }
            }
            if (items.isEmpty() && parentId == null) {
                Button(onClick = {
                    scope.launch {
                        busy = true
                        items = jfClient.browse(appSettings.jellyfinServer(), token, userId, null)
                        sessions = jfClient.sessions(appSettings.jellyfinServer(), token)
                        busy = false
                    }
                }, enabled = !busy) { Text("Load library") }
            }
            LazyColumn {
                items(items, key = { it.id }) { item ->
                    Card(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
                        Row(Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                (if (item.isFolder) "📁 " else "") + item.name,
                                style = MaterialTheme.typography.titleSmall,
                                modifier = Modifier.weight(1f),
                            )
                            if (!item.isFolder) {
                                TextButton(onClick = {
                                    val url = JellyfinApi.streamUrl(appSettings.jellyfinServer(), item.id, token)
                                    RigelIntake.handle(url)
                                }) { Text("Play") }
                            }
                        }
                    }
                }
            }
            if (sessions.isNotEmpty()) {
                Text("Cast library item to a client", style = MaterialTheme.typography.titleSmall)
                LazyColumn {
                    items(sessions, key = { it.id }) { s ->
                        TextButton(onClick = {
                            scope.launch {
                                val firstItem = items.firstOrNull { !it.isFolder }?.id
                                if (firstItem != null) {
                                    val ok = jfClient.playToSession(appSettings.jellyfinServer(), token, s.id, listOf(firstItem))
                                    notice = if (ok) "Sent to ${s.deviceName}" else "Cast failed"
                                } else {
                                    notice = "No playable item loaded"
                                }
                            }
                        }) { Text("Cast first playable item → ${s.deviceName} (${s.client})") }
                    }
                }
            }
        }
        notice?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
        Text(
            "Note: Jellyfin session remote control plays library items only — arbitrary URLs cannot be pushed to Jellyfin clients.",
            style = MaterialTheme.typography.bodySmall,
        )
    }
}

@Composable
private fun DevicesScreen() {
    var devices by remember { mutableStateOf<List<Pair<String, CastTarget>>>(emptyList()) }
    var scanning by remember { mutableStateOf(false) }
    var ipText by remember { mutableStateOf("") }
    var notice by remember { mutableStateOf<String?>(null) }
    val scope = androidx.compose.runtime.rememberCoroutineScope()

    LaunchedEffect(Unit) {
        scanning = true
        val found = appDevices.scan()
        devices = found.map { it.via to it.target }
        scanning = false
    }

    Column(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Devices", style = MaterialTheme.typography.headlineSmall, modifier = Modifier.weight(1f))
            TextButton(onClick = {
                AppState.screen.value = Screen.HOME
            }) { Text("Back") }
        }
        if (scanning) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(modifier = Modifier.size(20.dp))
                Spacer(Modifier.width(8.dp))
                Text("Scanning network…")
            }
        }
        Row {
            OutlinedTextField(
                value = ipText,
                onValueChange = { ipText = it },
                label = { Text("TV IP") },
                modifier = Modifier.weight(1f),
            )
            Spacer(Modifier.width(8.dp))
            Button(onClick = {
                scope.launch {
                    val added = appDevices.addManualByIp(ipText)
                    notice = if (added != null) "Added ${added.name}" else "No renderer found at $ipText"
                }
            }) { Text("Add") }
        }
        notice?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
        LazyColumn {
            items(devices, key = { it.second.name }) { (via, target) ->
                Card(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
                    Column(Modifier.padding(12.dp)) {
                        Text(target.name, style = MaterialTheme.typography.titleSmall)
                        Text(
                            when (target) {
                                is CastTarget.Dlna -> "DLNA renderer ($via)"
                                is CastTarget.Roku -> "Roku ($via)"
                                is CastTarget.Kodi -> "Kodi JSON-RPC ($via)"
                                is CastTarget.JellyfinSessionTarget -> "Jellyfin client"
                            },
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                }
            }
            if (devices.isEmpty() && !scanning) {
                item { Text("No devices found. Try 'Add by IP' — SSDP multicast may be restricted.") }
            }
        }
    }
}

@Composable
private fun SettingsScreen() {
    var showIntegration by remember { mutableStateOf(false) }
    var rendererNotice by remember { mutableStateOf<String?>(null) }
    var rendererOn by remember { mutableStateOf(false) }
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    val route = remember { appSettings.routeOverride() }
    val cap = remember { appSettings.transcodeCap() }
    Column(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Settings", style = MaterialTheme.typography.headlineSmall, modifier = Modifier.weight(1f))
            TextButton(onClick = { AppState.screen.value = Screen.HOME }) { Text("Back") }
        }
        if (showIntegration) {
            IntegrationHelp(onClose = { showIntegration = false })
            return@Column
        }
        Text("Playback route", style = MaterialTheme.typography.titleSmall)
        RouteOverride.entries.forEach { option ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                RadioButton(selected = route == option, onClick = {
                    appSettings.setRouteOverride(option)
                })
                Text(option.name)
            }
        }
        Text("Transcode cap", style = MaterialTheme.typography.titleSmall)
        TranscodeCap.entries.forEach { option ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                RadioButton(selected = cap == option, onClick = {
                    appSettings.setTranscodeCap(option)
                })
                Text(option.label)
            }
        }
        TextButton(onClick = { showIntegration = true }) { Text("Integration: how apps send streams to Rigel") }
        Text("DLNA renderer (receive pushes)", style = MaterialTheme.typography.titleSmall)
        Button(onClick = {
            scope.launch {
                if (!rendererOn) {
                    val error = app.rigel.bridge.RendererBridgeAccess.start()
                    if (error == null) {
                        rendererOn = true
                        rendererNotice = "Rigel now appears as a DLNA renderer (Kodi 'Play using…', BubbleUPnP, Jellyfin-web)"
                    } else {
                        rendererNotice = error
                    }
                } else {
                    app.rigel.bridge.RendererBridgeAccess.stop()
                    rendererOn = false
                    rendererNotice = null
                }
            }
        }) { Text(if (rendererOn) "Stop renderer" else "Start renderer") }
        rendererNotice?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
        Text(
            "Receive mode requires the multicast networking entitlement (Apple-gated); " +
                "it is off by default and degrades gracefully when unavailable.",
            style = MaterialTheme.typography.bodySmall,
        )
        Text(
            "Licenses: Rigel GPL-3.0; FFmpeg LGPL-3.0 (source: ffmpeg.org).",
            style = MaterialTheme.typography.bodySmall,
        )
    }
}

/** In-app scheme documentation so any app can target Rigel. */
@Composable
private fun IntegrationHelp(onClose: () -> Unit) {
    val grammar = "rigel://x-callback-url/{play|stream}?url=<enc>\\n" +
        "&filename=<enc>&sub=<enc,repeatable>&x-source=<enc>&x-success=<enc>"
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Integration", style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
            TextButton(onClick = onClose) { Text("Back") }
        }
        Text("Any app can hand a stream to Rigel:", style = MaterialTheme.typography.bodyMedium)
        Text(grammar, style = MaterialTheme.typography.bodySmall)
        Text(
            "Example (Nuvio-compatible):\nrigel://x-callback-url/play?url=https%3A%2F%2Fx%2Fv.mkv&filename=Movie&sub=https%3A%2F%2Fx%2Fs.vtt",
            style = MaterialTheme.typography.bodySmall,
        )
        Text(
            "Also accepts: plain http(s):// URLs, file:// (Files open-in), share sheet, " +
                "and launch with a rigel:// URL as an argument. Sender shows as 'via <x-source>' in the player.",
            style = MaterialTheme.typography.bodySmall,
        )
    }
}
