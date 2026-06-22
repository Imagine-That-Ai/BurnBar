import {
  Card, CardHeader, CardTitle, CardDescription, CardContent, Progress,
} from "@openburnbar/console";

export const Basic = () => (
  <Card style={{ maxWidth: 380 }}>
    <CardHeader>
      <CardTitle>Pensieve</CardTitle>
      <CardDescription>Your connected repositories and recall sources.</CardDescription>
    </CardHeader>
    <CardContent>
      <p style={{ margin: 0, fontSize: 14, color: "var(--color-text-base)" }}>
        3 repositories indexed · last recall 2h ago
      </p>
    </CardContent>
  </Card>
);

export const WithMeter = () => (
  <Card style={{ maxWidth: 380 }}>
    <CardHeader>
      <CardTitle>Encrypted vault</CardTitle>
      <CardDescription>Storage used this billing cycle.</CardDescription>
    </CardHeader>
    <CardContent>
      <Progress value={0.62} />
      <p style={{ margin: "10px 0 0", fontSize: 13, color: "var(--color-text-mute)" }}>
        6.2 GB of 10 GB
      </p>
    </CardContent>
  </Card>
);
