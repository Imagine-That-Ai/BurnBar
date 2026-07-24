import { useId, useState } from 'react';
import type { PendingQuestion } from '../../tauriBridge.js';
import type { ApprovalDecisionState } from '../../state/missionsStore.js';

export function QuestionCard({
  question,
  answerState,
  onAnswer
}: {
  question: PendingQuestion;
  answerState?: ApprovalDecisionState;
  onAnswer(answer: string, selectedOptionId?: string): Promise<boolean>;
}) {
  const fieldId = useId();
  const [answer, setAnswer] = useState('');
  const [selectedOptionId, setSelectedOptionId] = useState<string | undefined>();

  return (
    <article className="missions-question-card" aria-labelledby={`${fieldId}-title`}>
      <header className="missions-question-header">
        <div>
          <p className="missions-question-meta">
            {question.priority} priority · {question.projectSlug}
            {question.stageLabel ? ` · ${question.stageLabel}` : ''}
          </p>
          <h4 id={`${fieldId}-title`}>{question.title}</h4>
        </div>
        <span className="missions-question-status">Answer needed</span>
      </header>
      <p>{question.prompt}</p>
      {question.contextSummary ? <p className="muted">{question.contextSummary}</p> : null}
      {question.evidenceRefs.length > 0 ? (
        <p className="muted">Evidence: {question.evidenceRefs.join(', ')}</p>
      ) : null}

      <form
        className="missions-question-form"
        onSubmit={(event) => {
          event.preventDefault();
          void onAnswer(answer, selectedOptionId).then((ok) => {
            if (ok) {
              setAnswer('');
              setSelectedOptionId(undefined);
            }
          });
        }}
      >
        {question.suggestedOptions.length > 0 ? (
          <fieldset className="missions-question-options">
            <legend>Suggested answers</legend>
            {question.suggestedOptions.map((option) => (
              <label key={option.id}>
                <input
                  type="radio"
                  name={`${fieldId}-option`}
                  value={option.id}
                  checked={selectedOptionId === option.id}
                  onChange={() => {
                    setSelectedOptionId(option.id);
                    setAnswer(option.answer);
                  }}
                />
                <span>
                  <strong>{option.title}</strong>
                  {option.detail ? <small>{option.detail}</small> : null}
                </span>
              </label>
            ))}
          </fieldset>
        ) : null}
        <label className="missions-question-answer" htmlFor={`${fieldId}-answer`}>
          Answer
          <textarea
            id={`${fieldId}-answer`}
            value={answer}
            maxLength={16_384}
            placeholder={question.answerPlaceholder ?? 'Enter the operator answer'}
            onChange={(event) => {
              setAnswer(event.target.value);
              const option = question.suggestedOptions.find((item) => item.answer === event.target.value);
              setSelectedOptionId(option?.id);
            }}
          />
        </label>
        <div className="missions-question-actions">
          <button
            type="submit"
            className="missions-gate-btn missions-gate-btn--primary"
            disabled={answerState?.pending || answer.trim().length === 0}
            aria-busy={answerState?.pending}
          >
            {answerState?.pending ? 'Submitting…' : 'Submit answer'}
          </button>
          {question.dueAt ? <span className="muted">Due {question.dueAt}</span> : null}
        </div>
        {answerState?.error ? <p role="alert" className="missions-detail-unavailable">{answerState.error}</p> : null}
      </form>
    </article>
  );
}
