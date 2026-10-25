import { display } from '@kit.ArkUI';

export enum LayoutPreference {
  AUTO = 'auto',
  LAPTOP = 'laptop',
  NORMAL = 'normal'
}

export enum PostureState {
  NORMAL = 'normal',
  WAITING = 'waiting',
  LAPTOP = 'laptop'
}

export class CreaseRect {
  left: number = 0;
  top: number = 0;
  width: number = 0;
  height: number = 0;
}

export class PostureSnapshot {
  state: PostureState = PostureState.NORMAL;
  preference: LayoutPreference = LayoutPreference.AUTO;
  angle: number = -1;
  displayId: number = -1;
  windowTop: number = 0;
  windowDisplayId: number = -1;
  windowFullScreen: boolean = false;
  crease: CreaseRect[] = [];
  syntheticSplit: boolean = false;
  message: string = '普通布局';
}

export class PostureEngine {
  onChanged: (snapshot: PostureSnapshot) => void = (_snapshot: PostureSnapshot): void => {};
  private preference: LayoutPreference = LayoutPreference.AUTO;
  private state: PostureState = PostureState.NORMAL;
  private angle: number = -1;
  private foldStatus: display.FoldStatus = display.FoldStatus.FOLD_STATUS_UNKNOWN;
  private displayMode: display.FoldDisplayMode = display.FoldDisplayMode.FOLD_DISPLAY_MODE_UNKNOWN;
  private crease: CreaseRect[] = [];
  private displayId: number = -1;
  private windowTopPx: number = 0;
  private windowDisplayId: number = -1;
  private windowFullScreen: boolean = false;
  private windowGeometryValid: boolean = false;
  private started: boolean = false;
  private timer: number = -1;
  private foldCallback = (status: display.FoldStatus): void => {
    this.foldStatus = status;
    this.evaluate();
  };
  private angleCallback = (angles: Array<number>): void => {
    if (angles.length > 0) {
      this.angle = angles[0];
      this.evaluate();
    }
  };
  private displayModeCallback = (mode: display.FoldDisplayMode): void => {
    this.displayMode = mode;
    this.evaluate();
  };

  static isHorizontalCrease(rect: CreaseRect): boolean {
    return Number.isFinite(rect.left) && Number.isFinite(rect.top) &&
      Number.isFinite(rect.width) && Number.isFinite(rect.height) &&
      rect.height >= 0 && rect.width > rect.height;
  }

  start(): void {
    if (this.started) {
      return;
    }
    this.started = true;
    try {
      this.foldStatus = display.getFoldStatus();
      this.displayMode = display.getFoldDisplayMode();
      display.on('foldStatusChange', this.foldCallback);
      display.on('foldAngleChange', this.angleCallback);
      display.on('foldDisplayModeChange', this.displayModeCallback);
    } catch (_error) {
      this.state = PostureState.NORMAL;
    }
    this.refreshGeometry();
    this.evaluate();
  }

  stop(): void {
    if (!this.started) {
      return;
    }
    this.started = false;
    this.cancelTimer();
    try {
      display.off('foldStatusChange', this.foldCallback);
      display.off('foldAngleChange', this.angleCallback);
      display.off('foldDisplayModeChange', this.displayModeCallback);
    } catch (_error) {
    }
  }

  setPreference(preference: LayoutPreference): void {
    this.preference = preference;
    this.cancelTimer();
    this.refreshGeometry();
    this.evaluate();
  }

  notifyWindowChanged(): void {
    this.refreshGeometry();
    this.evaluate();
  }

  updateWindowGeometry(topPx: number, displayId: number, fullScreen: boolean, valid: boolean): void {
    this.windowTopPx = topPx;
    this.windowDisplayId = displayId;
    this.windowFullScreen = fullScreen;
    this.windowGeometryValid = valid;
    this.refreshGeometry();
    this.evaluate();
  }

  private refreshGeometry(): void {
    try {
      const current = display.getDefaultDisplaySync();
      this.displayId = current.id;
      const density = current.densityPixels > 0 ? current.densityPixels : 1;
      let region = current.getLiveCreaseRegion();
      if (region === undefined || region.creaseRects.length === 0) {
        region = display.getCurrentFoldCreaseRegion();
      }
      this.crease = [];
      if (region !== undefined) {
        for (let index = 0; index < region.creaseRects.length; index++) {
          const source = region.creaseRects[index];
          const target = new CreaseRect();
          target.left = (source.left ?? 0) / density;
          target.top = (source.top ?? 0) / density;
          target.width = source.width / density;
          target.height = source.height / density;
          this.crease.push(target);
        }
      }
    } catch (_error) {
      this.crease = [];
    }
  }

  private evaluate(): void {
    if (this.preference === LayoutPreference.NORMAL) {
      this.cancelTimer();
      this.publish(PostureState.NORMAL, '普通布局');
      return;
    }
    if (this.preference === LayoutPreference.LAPTOP) {
      this.publish(PostureState.LAPTOP, '手动上下布局');
      return;
    }
    if (this.state === PostureState.LAPTOP) {
      if (!this.hasValidGeometry() || this.angle < 65 || this.angle > 120) {
        this.publish(PostureState.NORMAL, '已退出类笔记本姿态');
      } else {
        this.publish(PostureState.LAPTOP, '类笔记本布局');
      }
      return;
    }
    if (!this.hasValidGeometry() || this.foldStatus !== display.FoldStatus.FOLD_STATUS_HALF_FOLDED ||
      this.angle < 75 || this.angle > 105) {
      this.cancelTimer();
      this.publish(PostureState.NORMAL, '普通布局');
      return;
    }
    if (this.timer < 0) {
      this.publish(PostureState.WAITING, '等待姿态稳定');
      this.timer = setTimeout((): void => {
        this.timer = -1;
        if (this.preference === LayoutPreference.AUTO && this.hasValidGeometry() &&
          this.foldStatus === display.FoldStatus.FOLD_STATUS_HALF_FOLDED && this.angle >= 75 && this.angle <= 105) {
          this.publish(PostureState.LAPTOP, '类笔记本布局');
        } else {
          this.publish(PostureState.NORMAL, '普通布局');
        }
      }, 200);
    }
  }

  private hasValidGeometry(): boolean {
    if (!this.windowGeometryValid || !this.windowFullScreen || this.windowDisplayId !== this.displayId) {
      return false;
    }
    try {
      if (!display.isFoldable() || this.displayMode !== display.FoldDisplayMode.FOLD_DISPLAY_MODE_FULL) {
        return false;
      }
    } catch (_error) {
      return false;
    }
    for (let index = 0; index < this.crease.length; index++) {
      const rect = this.crease[index];
      if (PostureEngine.isHorizontalCrease(rect)) {
        return true;
      }
    }
    return false;
  }

  private publish(state: PostureState, message: string): void {
    this.state = state;
    const snapshot = new PostureSnapshot();
    snapshot.state = state;
    snapshot.preference = this.preference;
    snapshot.angle = this.angle;
    snapshot.displayId = this.displayId;
    snapshot.windowDisplayId = this.windowDisplayId;
    snapshot.windowFullScreen = this.windowFullScreen;
    try {
      const current = display.getDefaultDisplaySync();
      const density = current.densityPixels > 0 ? current.densityPixels : 1;
      snapshot.windowTop = this.windowTopPx / density;
    } catch (_error) {
      snapshot.windowTop = 0;
    }
    snapshot.crease = this.crease;
    snapshot.syntheticSplit = this.preference === LayoutPreference.LAPTOP &&
      (!this.crease.some((rect: CreaseRect): boolean => PostureEngine.isHorizontalCrease(rect)) ||
        !this.windowGeometryValid || !this.windowFullScreen ||
        this.windowDisplayId !== this.displayId);
    snapshot.message = message;
    this.onChanged(snapshot);
  }

  private cancelTimer(): void {
    if (this.timer >= 0) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
    if (this.state === PostureState.WAITING) {
      this.state = PostureState.NORMAL;
    }
  }
}
