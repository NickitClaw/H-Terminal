import { LayoutPreference, PostureEngine, PostureSnapshot, PostureState } from './PostureEngine';

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
      let top = -1;
      let bottom = -1;
      if (!snapshot.syntheticSplit) {
        for (let index = 0; index < snapshot.crease.length; index++) {
          const rect = snapshot.crease[index];
          if (!PostureEngine.isHorizontalCrease(rect) || rect.left >= width || rect.left + rect.width <= 0) {
            continue;
          }
          const candidateTop = rect.top - snapshot.windowTop - rootGlobalY;
          const candidateBottom = candidateTop + rect.height;
          if (candidateTop >= 160 && height - candidateBottom >= 200) {
            top = candidateTop;
            bottom = candidateBottom;
            break;
          }
        }
      }
      if (top < 0 && snapshot.preference === LayoutPreference.LAPTOP) {
        top = height / 2;
        bottom = top;
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
