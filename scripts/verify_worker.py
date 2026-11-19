"""Offline smoke check for the municipal CSV/JSON export parser."""

from backend.app.worker import MunicipalIssue, _records


class FakeResponse:
    def __init__(self, content_type, body):
        self.headers = {"content-type": content_type}
        self.text = body
        self._body = body

    def json(self):
        import json

        return json.loads(self._body)


def main() -> None:
    json_records = _records(
        FakeResponse(
            "application/json",
            '[{"ticket_id":"TEST-1","category":"pothole","description":"Road damage report","latitude":17.4,"longitude":78.4}]',
        )
    )
    csv_records = _records(
        FakeResponse(
            "text/csv",
            "ticket_id,category,description,locality\nTEST-2,open_manhole,Open manhole reported,Begumpet\n",
        )
    )
    assert len(json_records) == 1
    assert MunicipalIssue.model_validate(json_records[0]).ticket_id == "TEST-1"
    assert MunicipalIssue.model_validate(csv_records[0]).locality == "Begumpet"
    try:
        _records(FakeResponse("text/html", "<html>login form</html>"))
    except ValueError:
        pass
    else:
        raise AssertionError("Interactive HTML pages must not be accepted as feeds")
    print("Municipal JSON/CSV parser smoke check passed")


if __name__ == "__main__":
    main()
