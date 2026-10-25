import { PostureSnapshot, PostureState } from './PostureEngine';

export class LayoutResult {
  terminalWidth: number = 0;
  terminalHeight: number = 0;
  keyboardY: number = 0;
  keyboardWidth: number = 0;
  keyboardHeight: number = 0;
  laptop: boolean = false;
}

export class LayoutCoordinator {
  static compute(width: number, height: number, rootGlobalY: number, snapshot: PostureSnapshot,
    keyboardVisible: boolean, imeVisible: boolean): LayoutResult {
    const result = new LayoutResult();
    result.terminalWidth = width;
    result.terminalHeight = Math.max(0, height);
    result.keyboardY = height;
    result.keyboardWidth = width;
    if (width <= 0 || height <= 0 || !keyboardVisible || imeVisible) {
      return result;
    }

    if (snapshot.state === PostureState.LAPTOP) {
      let top = height / 2;
      let bottom = height / 2;
      if (snapshot.crease.length > 0 && !snapshot.syntheticSplit) {
        const rect = snapshot.crease[0];
        top = rect.top - snapshot.windowTop - rootGlobalY;
        bottom = rect.top + rect.height - snapshot.windowTop - rootGlobalY;
      } else if (!snapshot.syntheticSplit) {
        return LayoutCoordinator.normalLayout(result, width, height);
      }
      if (top >= 160 && height - bottom >= 200 && bottom >= top) {
        result.terminalHeight = top;
        result.keyboardY = bottom;
        result.keyboardHeight = height - bottom;
        result.laptop = true;
        return result;
      }
    }
    return LayoutCoordinator.normalLayout(result, width, height);
  }

  private static normalLayout(result: LayoutResult, width: number, height: number): LayoutResult {
    const keyboardHeight = Math.min(320, Math.max(200, height * 0.45));
    if (height - keyboardHeight >= 160) {
      result.terminalHeight = height - keyboardHeight;
      result.keyboardY = height - keyboardHeight;
      result.keyboardHeight = keyboardHeight;
    }
    result.terminalWidth = width;
    result.keyboardWidth = width;
    result.laptop = false;
    return result;
  }
}
