import { ModifierSnapshot } from '../input/InputRouter';
import { KeyDefinition, KeyboardLayoutMode, KeyboardModel, KeyboardRow } from '../input/KeyboardModel';

@Component
struct KeyboardKey {
  @Prop definition: KeyDefinition = new KeyDefinition('space', 'Space', 'text', ' ', ' ');
  @Prop active: boolean = false;
  @Prop inputEnabled: boolean = true;
  onTap: (definition: KeyDefinition) => void = (_definition: KeyDefinition): void => {};

  build() {
    Button({ type: ButtonType.Normal }) {
      Column() {
        if (this.definition.subLabel.length > 0) {
          Text(this.definition.subLabel)
            .fontSize(9)
            .fontColor('#9AA9B8')
            .maxLines(1)
        }
        Text(this.definition.label)
          .fontSize(this.definition.label.length > 5 ? 10 : 13)
          .fontColor('#E5EDF5')
          .maxLines(1)
      }
      .alignItems(HorizontalAlign.Center)
      .justifyContent(FlexAlign.Center)
    }
    .layoutWeight(this.definition.width)
    .height('100%')
    .padding(1)
    .margin(1)
    .borderRadius(4)
    .backgroundColor(this.active ? '#376F65' : '#263442')
    .enabled(this.inputEnabled)
    .accessibilityText(this.definition.label)
    .onClick((): void => {
      this.onTap(this.definition);
    })
  }
}

@Component
export struct LaptopKeyboard {
  @Prop mode: KeyboardLayoutMode = KeyboardLayoutMode.COMPACT;
  @Prop symbols: boolean = false;
  @Prop inputEnabled: boolean = true;
  @Prop modifiers: ModifierSnapshot = new ModifierSnapshot();
  onKey: (definition: KeyDefinition) => void = (_definition: KeyDefinition): void => {};

  private isActive(definition: KeyDefinition): boolean {
    if (definition.kind !== 'modifier') {
      return false;
    }
    if (definition.id === 'ctrl') {
      return this.modifiers.ctrl;
    }
    if (definition.id === 'alt' || definition.id === 'altgr') {
      return this.modifiers.alt;
    }
    if (definition.id === 'shift') {
      return this.modifiers.shift;
    }
    if (definition.id === 'fn') {
      return this.modifiers.fn;
    }
    return this.modifiers.caps;
  }

  build() {
    Column() {
      ForEach(KeyboardModel.rows(this.mode, this.symbols), (row: KeyboardRow, rowIndex: number) => {
        Row() {
          ForEach(row.keys, (definition: KeyDefinition, keyIndex: number) => {
            KeyboardKey({
              definition: definition,
              active: this.isActive(definition),
              inputEnabled: this.inputEnabled,
              onTap: this.onKey
            })
          }, (definition: KeyDefinition, keyIndex: number): string => `${rowIndex}-${keyIndex}-${definition.id}`)
        }
        .width('100%')
        .layoutWeight(row.weight)
      }, (row: KeyboardRow, rowIndex: number): string => `${this.mode}-${this.symbols}-${rowIndex}`)
    }
    .width('100%')
    .height('100%')
    .padding(2)
    .backgroundColor('#111821')
  }
}
