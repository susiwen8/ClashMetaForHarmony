import type { ProfileRowState } from '../presentation/PresentationModels';

@Component
export struct ProfileListItem {
  @Prop row: ProfileRowState;
  onOpenProfile: (profileId: string) => void = (_profileId: string) => {
  };

  build() {
    Column({ space: $r('app.float.space_md') }) {
      Row({ space: $r('app.float.space_sm') }) {
        Text(this.row.name)
          .fontSize($r('app.float.type_body'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.color_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        if (this.row.active) {
          buildBadge($r('app.string.profiles_badge_active'), $r('app.color.color_action_primary'));
        }
        buildBadge(availabilityLabel(this.row.availability), availabilityColor(this.row.availability));
      }
      .width('100%')

      Text(this.row.sourceDisplay)
        .fontSize($r('app.float.type_caption'))
        .fontColor($r('app.color.color_text_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Text(this.row.updatedAt)
        .fontSize($r('app.float.type_caption'))
        .fontColor($r('app.color.color_text_secondary'))
    }
    .id(`profiles.row.${this.row.id}`)
    .width('100%')
    .padding($r('app.float.space_lg'))
    .constraintSize({ minHeight: $r('app.float.touch_target_min') })
    .borderRadius($r('app.float.radius_card'))
    .backgroundColor($r('app.color.color_surface_card'))
    .border({
      width: 1,
      color: $r('app.color.color_border_subtle')
    })
    .onClick(() => {
      this.onOpenProfile(this.row.id);
    })
  }
}

@Builder
function buildBadge(label: Resource, color: Resource): void {
  Text(label)
    .fontSize($r('app.float.type_caption'))
    .fontColor(color)
    .padding({
      left: $r('app.float.space_sm'),
      right: $r('app.float.space_sm'),
      top: $r('app.float.space_xs'),
      bottom: $r('app.float.space_xs')
    })
    .backgroundColor($r('app.color.color_surface_subtle'))
    .borderRadius($r('app.float.radius_chip'))
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
