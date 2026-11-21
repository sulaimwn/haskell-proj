import { describe, expect, it } from 'vitest'
import { fakeBackend } from '../testing'
import { api, ApiError, toUploadedFile } from './client'

describe('the API client', () => {
  it('leaves unset filters out of the URL', async () => {
    const calls = fakeBackend({ 'GET /api/accounts/1234/transactions': [] })
    await api.getTransactions('1234', { from: '', search: 'grocery', limit: 50 })
    expect(calls[0]?.url).toBe('/api/accounts/1234/transactions?q=grocery&limit=50')
  })

  it('sends writes as JSON, which is all the server accepts', async () => {
    const calls = fakeBackend({ 'POST /api/accounts/1234/checkpoints': { message: 'ok', details: [] } })
    await api.addCheckpoint('1234', { date: '2026-02-28', balanceCents: 155243 })
    expect(calls[0]?.method).toBe('POST')
    expect(calls[0]?.headers['Content-Type']).toBe('application/json')
    expect(calls[0]?.body).toEqual({ date: '2026-02-28', balanceCents: 155243 })
  })

  it("shows the server's own explanation when it refuses", async () => {
    fakeBackend({ 'POST /api/rows/7/settle': { status: 422, body: { problem: 'That row is part of a transfer pair.' } } })
    const failure = await api.settleRow(7, { account: 'income:refunds' }).catch((error: unknown) => error)
    expect(failure).toBeInstanceOf(ApiError)
    expect((failure as ApiError).message).toBe('That row is part of a transfer pair.')
    expect((failure as ApiError).status).toBe(422)
  })

  it('falls back to the status line when the body is not an explanation', async () => {
    fakeBackend({ 'GET /api/review': { status: 502, body: 'bad gateway' } })
    const failure = await api.getReview().catch((error: unknown) => error)
    expect((failure as ApiError).message).toContain('502')
  })

  it('encodes a file as base64 without losing bytes', async () => {
    const bytes = new Uint8Array([0, 1, 2, 250, 251, 252, 253, 254, 255])
    const uploaded = await toUploadedFile(new File([bytes], 'export.csv'))
    expect(uploaded.fileName).toBe('export.csv')
    expect(Uint8Array.from(atob(uploaded.contentBase64), (character) => character.charCodeAt(0))).toEqual(bytes)
  })
})
