<script lang="ts">
  import { Label } from '$lib/components/ui/label';
  import * as NativeSelect from '$lib/components/ui/native-select';
  import { initializeAppearance, isAppearance } from './lib/appearance';
  let { id }: { id: string } = $props();
  const preference = initializeAppearance();
</script>

<div class="appearance-picker">
  <Label for={`${id}-appearance`}>Appearance</Label>
  <NativeSelect.Root id={`${id}-appearance`} value={$preference} onchange={(event) => {
    const value = event.currentTarget.value;
    if (isAppearance(value)) preference.set(value);
  }}>
    <option value="system">System</option>
    <option value="light">Light</option>
    <option value="dark">Dark</option>
  </NativeSelect.Root>
</div>
