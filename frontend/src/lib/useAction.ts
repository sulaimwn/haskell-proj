import { useMutation, useQueryClient } from '@tanstack/react-query'
import type { ActionResult } from '../api/generated'

/**
 * A button press that changes the ledger. Every such action can change what
 * any page shows (a posted row moves a balance, a review item, a checkpoint),
 * so on success all cached queries are refetched rather than guessing which.
 */
export function useAction<Input>(run: (input: Input) => Promise<ActionResult>) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: run,
    onSuccess: () => queryClient.invalidateQueries(),
  })
}
