import type { ProfileRowState } from '../presentation/PresentationModels';

@Component
export struct ProfileListItem {
  @Prop row: ProfileRowState;
  onOpenProfile: (profileId: string) => void = (_profileId: string) => {
  };

  build() {
    Column() {
      Row({ space: $r('app.float.space_md') }) {
        Text(profileMonogram(this.row.name))
          .fontSize($r('app.float.type_body'))
          .fontWeight(FontWeight.Bold)
          .fontColor(this.row.active
            ? $r('app.color.color_text_inverse')
            : $r('app.color.color_text_primary'))
          .width(42)
          .height(42)
          .textAlign(TextAlign.Center)
          .backgroundColor(this.row.active
            ? $r('app.color.color_action_primary')
            : $r('app.color.color_surface_subtle'))
          .borderRadius($r('app.float.radius_action'))

        Column({ space: $r('app.float.space_xs') }) {
          Row({ space: $r('app.float.space_sm') }) {
            Text(this.row.name)
              .fontSize($r('app.float.type_body'))
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.color_text_primary'))
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })

            if (this.row.active) {
              buildBadge($r('app.string.profiles_badge_active'), $r('app.color.color_action_primary'));
            }
            buildBadge(availabilityLabel(this.row.availability), availabilityColor(this.row.availability));
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Text(this.row.sourceDisplay)
            .fontSize($r('app.float.type_caption'))
            .fontColor($r('app.color.color_text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Start)

          Text(formatProfileUpdatedAt(this.row.updatedAt))
            .fontSize($r('app.float.type_caption'))
            .fontColor($r('app.color.color_text_secondary'))
            .width('100%')
            .textAlign(TextAlign.Start)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .padding($r('app.float.space_md'))
      .alignItems(VerticalAlign.Center)

      Divider()
        .color($r('app.color.color_border_subtle'))
        .margin({ left: 62 })
    }
    .id(`profiles.row.${this.row.id}`)
    .width('100%')
    .constraintSize({ minHeight: $r('app.float.touch_target_min') })
    .backgroundColor($r('app.color.color_surface_card'))
    .onClick(() => {
      this.onOpenProfile(this.row.id);
    })
  }
}

@Builder
function buildBadge(label: Resource, color: Resource): void {
  Text(label)
    .fontSize($r('app.float.type_caption'))
    .fontWeight(FontWeight.Medium)
    .fontColor(color)
    .padding({
      left: $r('app.float.space_sm'),
      right: $r('app.float.space_sm'),
      top: 2,
      bottom: 2
    })
    .backgroundColor($r('app.color.color_surface_subtle'))
    .borderRadius($r('app.float.radius_chip'))
}

function profileMonogram(name: string): string {
  const normalized: string = name.trim();
  if (normalized.length === 0) {
    return '';
  }
  return normalized.substring(0, 1).toUpperCase();
}

function formatProfileUpdatedAt(timestamp: string): string {
  const normalized: string = timestamp.trim().replace('T', ' ');
  if (normalized.length <= 16) {
    return normalized;
  }
  return normalized.substring(0, 16);
}

function availabilityLabel(availability: 'VALID' | 'INVALID' | 'UPDATE_FAILED_USING_VALID') {
  switch (availability) {
    case 'VALID':
      return $r('app.string.profiles_badge_valid');
    case 'UPDATE_FAILED_USING_VALID':
      return $r('app.string.profiles_badge_update_failed');
    case 'INVALID':
    default:
      return $r('app.string.profiles_badge_invalid');
  }
}

function availabilityColor(availability: 'VALID' | 'INVALID' | 'UPDATE_FAILED_USING_VALID') {
  switch (availability) {
    case 'VALID':
      return $r('app.color.color_status_success');
    case 'UPDATE_FAILED_USING_VALID':
      return $r('app.color.color_status_warning');
    case 'INVALID':
    default:
      return $r('app.color.color_status_danger');
  }
}
