import { abilityAccessCtrl, common, wantAgent, Permissions, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { geoLocationManager } from '@kit.LocationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const LOG_DOMAIN = 0x0000;
const LOG_TAG = '[DSH-KeepAlive]';
const APPROXIMATE_PERMISSION: Permissions[] = ['ohos.permission.APPROXIMATELY_LOCATION'];
const BACKGROUND_PERMISSION: Permissions[] = ['ohos.permission.LOCATION_IN_BACKGROUND'];

/**
 * DSH HOS 后台保活。
 *
 * 使用定位类连续任务，让 HarmonyOS 在应用切到后台后仍把进程当作前台服务。
 * 连续任务不是“永久保活”：系统仍可能因低内存、用户强制停止或省电策略回收。
 *
 * 开关由 DSH 设置页写入 $DSH_HOME/harmony-native.json，壳层轮询后调用
 * start()/stop()。所有启停操作串行执行，并用 generation 丢弃过期请求。
 */
export class BackgroundKeepAlive {
  private running = false;
  private locationSubscribed = false;
  private generation = 0;
  private serial: Promise<void> = Promise.resolve();
  private retryAt = 0;

  start(context: common.UIAbilityContext): Promise<boolean> {
    const generation = ++this.generation;
    const task = this.serial.then(
      () => this.enable(context, generation),
      () => this.enable(context, generation));
    this.serial = task.then(() => {}, () => {});
    return task;
  }

  stop(context: common.UIAbilityContext): Promise<void> {
    ++this.generation;
    const task = this.serial.then(
      () => this.disable(context),
      () => this.disable(context));
    this.serial = task.then(() => {}, () => {});
    return task;
  }

  private async enable(context: common.UIAbilityContext, generation: number): Promise<boolean> {
    if (generation !== this.generation) { return false; }
    if (this.running) { return true; }
    if (Date.now() < this.retryAt) { return false; }

    const granted = await this.askLocation(context);
    if (!granted || generation !== this.generation) {
      if (!granted) {
        this.retryAt = Date.now() + 30000;
        hilog.info(LOG_DOMAIN, LOG_TAG, 'location permission denied; retry later');
      }
      return false;
    }

    let addedSubscription = false;
    try {
      if (!this.locationSubscribed) {
        geoLocationManager.on('locationChange', {
          interval: 20,
          locationScenario: geoLocationManager.PowerConsumptionScenario.LOW_POWER_CONSUMPTION
        }, () => {});
        this.locationSubscribed = true;
        addedSubscription = true;
      }

      const agent = await this.buildWantAgent(context);
      if (generation !== this.generation) {
        this.dropLocation(addedSubscription);
        return false;
      }

      await backgroundTaskManager.startBackgroundRunning(
        context, backgroundTaskManager.BackgroundMode.LOCATION, agent);

      if (generation !== this.generation) {
        await this.stopContinuousTask(context);
        this.dropLocation(addedSubscription);
        return false;
      }

      this.running = true;
      hilog.info(LOG_DOMAIN, LOG_TAG, 'continuous location task started');
      return true;
    } catch (error) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'start failed: %{public}s', (error as Error).message);
      await this.stopContinuousTask(context);
      this.dropLocation(addedSubscription);
      return false;
    }
  }

  private async disable(context: common.UIAbilityContext): Promise<void> {
    if (this.locationSubscribed) {
      try { geoLocationManager.off('locationChange'); } catch (error) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'unsubscribe failed: %{public}s', (error as Error).message);
      }
      this.locationSubscribed = false;
    }
    await this.stopContinuousTask(context);
  }

  private async askLocation(context: common.UIAbilityContext): Promise<boolean> {
    try {
      const manager = abilityAccessCtrl.createAtManager();
      // 先只要模糊定位：这是连续任务的最低要求，用户拒绝时不应每 3 秒重复弹窗。
      const result = await manager.requestPermissionsFromUser(context, APPROXIMATE_PERMISSION);
      if (result.authResults.length === 0 || result.authResults[0] !== 0) { return false; }
      // 后台定位是可选增强；被拒时仍允许尝试启动，最终由系统连续任务校验决定。
      try {
        await manager.requestPermissionsFromUser(context, BACKGROUND_PERMISSION);
      } catch (error) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'background location request failed: %{public}s', (error as Error).message);
      }
      return true;
    } catch (error) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'permission request failed: %{public}s', (error as Error).message);
      return false;
    }
  }

  private async buildWantAgent(context: common.UIAbilityContext): Promise<WantAgent> {
    return wantAgent.getWantAgent({
      wants: [{
        bundleName: context.abilityInfo.bundleName,
        abilityName: context.abilityInfo.name
      }],
      operationType: wantAgent.OperationType.START_ABILITY,
      requestCode: 1,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    });
  }

  private async stopContinuousTask(context: common.UIAbilityContext): Promise<void> {
    if (!this.running) { return; }
    try {
      await backgroundTaskManager.stopBackgroundRunning(context);
    } catch (error) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'stop failed: %{public}s', (error as Error).message);
    }
    this.running = false;
  }

  private dropLocation(added: boolean): void {
    if (!added || !this.locationSubscribed) { return; }
    try { geoLocationManager.off('locationChange'); } catch (error) { /* best effort */ }
    this.locationSubscribed = false;
  }
}
