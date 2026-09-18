import os from "node:os";
import path from "node:path";
import { createRemoteGateway, deviceAuthenticator } from "./remote-gateway.mjs";
const authenticate = deviceAuthenticator(path.join(os.homedir(), "Library/Application Support/CodexWatchRemote/devices.json"));
authenticate(undefined); // Refuse to start if the registry is missing or unsafe.
const server = createRemoteGateway({ authenticate });
server.listen(17843, "127.0.0.1", () => console.log("Authenticated remote gateway ready on loopback:17843"));
