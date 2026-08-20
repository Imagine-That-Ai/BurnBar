import { SafariBackgroundController } from './controller';
import { BrowserNativeMessagingAdapter, NativeBridge } from './nativeBridge';
import { getBrowserAPI } from '../shared/browser';
import { isPopupRequest } from '../shared/messages';

const browserAPI = getBrowserAPI();
const nativeBridge = new NativeBridge({
  adapter: new BrowserNativeMessagingAdapter(browserAPI),
  extensionVersion: browserAPI.runtime.getManifest().version
});
const controller = new SafariBackgroundController(browserAPI, nativeBridge);

browserAPI.runtime.onMessage.addListener((message) => {
  if (!isPopupRequest(message)) {
    return undefined;
  }
  return controller.handlePopupRequest(message);
});

browserAPI.runtime.onInstalled?.addListener(() => {
  void controller.initialize(true);
});

browserAPI.runtime.onStartup?.addListener(() => {
  void controller.initialize(true);
});

if (browserAPI.alarms) {
  const alarmName = 'openburnbar-safari-bridge-heartbeat';
  void browserAPI.alarms.create(alarmName, { delayInMinutes: 0.2, periodInMinutes: 1 });
  browserAPI.alarms.onAlarm.addListener((alarm) => {
    if (alarm.name === alarmName) {
      void controller.initialize();
    }
  });
}
